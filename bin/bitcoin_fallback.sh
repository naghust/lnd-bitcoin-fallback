#!/usr/bin/env bash

# ---------------------------------------------
# bitcoin_fallback.sh
# Script para verificar a conexão com o node Bitcoin Core principal
# e realizar fallback para um node backup, ajustando a configuração do LND.
# Utiliza curl para testar a conexão RPC, não requer bitcoin-cli local.
# ---------------------------------------------

# Habilita modos de erro estritos
set -euo pipefail

# --------------------------------------------------------------------------------
# Resolve symlinks e pega o diretório real do script
# --------------------------------------------------------------------------------
SOURCE="${BASH_SOURCE[0]}"
while [ -h "$SOURCE" ]; do
  DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"
  SOURCE="$(readlink "$SOURCE")"
  [[ $SOURCE != /* ]] && SOURCE="$DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" >/dev/null 2>&1 && pwd)"

# --- Define diretórios baseados na localização do script ---
BIN_DIR="$SCRIPT_DIR"
PROJECT_ROOT="$(dirname "$BIN_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"

# --- Funções Auxiliares ---
TIMESTAMP() { date                      '+%Y-%m-%d %H:%M:%S'; }
log_error() { echo "[$(TIMESTAMP)] ERRO: $*" | tee -a "$LOG_FILE" >&2; }
log_info() { echo "[$(TIMESTAMP)] INFO: $*" | tee -a "$LOG_FILE"; }

# --- Carrega configurações e valida ---
CONFIG_FILE="$CONFIG_DIR/config.ini"
if [ ! -f "$CONFIG_FILE" ]; then
  # Não podemos logar no arquivo de log padrão ainda
  echo "[$(date                         '+%Y-%m-%d %H:%M:%S')] ERRO: Arquivo de configuração '$CONFIG_FILE' não encontrado." >&2
  exit 1
fi

# Carrega diretórios e arquivos de configuração
LND_DIR=$(crudini --get "$CONFIG_FILE" General LND_DIR 2>/dev/null || echo "")
LOG_FILE="${LND_DIR}/lnd_fallback.log" # Nome de log mais específico
STATE_FILE="$CONFIG_DIR/.fallback_state"

# Valida se LND_DIR foi carregado
if [ -z "$LND_DIR" ]; then
    # Tenta criar um log temporário se LND_DIR falhar
    LOG_FILE="/tmp/lnd_fallback_error.log"
    log_error "LND_DIR não definido na seção [General] de '$CONFIG_FILE'."
    exit 1
fi

# Cria o diretório de log se não existir
mkdir -p "$(dirname "$LOG_FILE")"

# Carrega detalhes de conexão e credenciais RPC do node PRINCIPAL
BITCOIN_RPC_HOST=$(crudini --get "$CONFIG_FILE" bitcoin_fallback BITCOIN_RPC_HOST 2>/dev/null || echo "")
BITCOIN_RPC_PORT=$(crudini --get "$CONFIG_FILE" bitcoin_fallback BITCOIN_RPC_PORT 2>/dev/null || echo "")
BITCOIN_RPC_USER=$(crudini --get "$CONFIG_FILE" bitcoin_fallback BITCOIN_RPC_USER 2>/dev/null || echo "")
BITCOIN_RPC_PASS=$(crudini --get "$CONFIG_FILE" bitcoin_fallback BITCOIN_RPC_PASS 2>/dev/null || echo "")

# Valida se os detalhes de conexão e credenciais RPC foram carregados
if [ -z "$BITCOIN_RPC_HOST" ] || [ -z "$BITCOIN_RPC_PORT" ] || [ -z "$BITCOIN_RPC_USER" ] || [ -z "$BITCOIN_RPC_PASS" ]; then
    log_error "Detalhes de conexão incompletos (BITCOIN_RPC_HOST, BITCOIN_RPC_PORT, BITCOIN_RPC_USER, BITCOIN_RPC_PASS) na seção [bitcoin_fallback] de '$CONFIG_FILE'."
    exit 1
fi

# Carrega script de notificação
# shellcheck source=./notify.sh
source "$BIN_DIR/notify.sh"

# --- Lógica Principal ---

# 1) Lê estado atual (principal|backup); default=principal
CURRENT_STATE="principal" # Assume principal se o arquivo não existir
if [ -f "$STATE_FILE" ]; then
    CURRENT_STATE=$(<"$STATE_FILE")
fi

# 2) Função para verificar a conexão com o Bitcoin Core Principal via curl
check_bitcoin_connection() {
    local rpc_url="http://$BITCOIN_RPC_HOST:$BITCOIN_RPC_PORT/"
    local rpc_user_pass="$BITCOIN_RPC_USER:$BITCOIN_RPC_PASS"
    local json_payload='{"jsonrpc": "1.0", "id":"fallback_check", "method": "getblockchaininfo", "params": [] }'

    # Usa curl para fazer a chamada RPC com timeout
    # Verifica o código de saída do curl E se a resposta contém "result" (indicativo de sucesso RPC)
    # O timeout é aplicado à conexão (--connect-timeout) e ao tempo total da operação (-m)
    local response
    response=$(curl --silent --fail \
                    --connect-timeout 5 -m 10 \
                    --user "$rpc_user_pass" \
                    --data-binary "$json_payload" \
                    -H 'content-type: text/plain;' "$rpc_url")

    # Verifica se a resposta contém um campo "result"
    if echo "$response" | grep -q '"result"'; then
        return 0
    else
        return 1
    fi
}

# 3) Função de troca de estado: copia conf, notifica e reinicia serviços
switch_state() {
    local new_state=$1
    local old_state=$CURRENT_STATE
    local lnd_conf_source="$CONFIG_DIR/lnd.$new_state.conf"
    local lnd_conf_target="$LND_DIR/lnd.conf"

    log_info "Iniciando troca de estado de '$old_state' para '$new_state'."

    # Notifica a troca
    notify "🔄 LND Fallback: Iniciando a troca do node bitcoin $old_state para o $new_state."

    # Verifica se o arquivo de configuração de origem existe
    if [ ! -f "$lnd_conf_source" ]; then
        log_error "Arquivo de configuração '$lnd_conf_source' não encontrado! Abortando troca."
        notify "🚨 ERRO Fallback: Arquivo '$lnd_conf_source' não encontrado!"
        exit 1
    fi

    # Copia a configuração correspondente
    if cp "$lnd_conf_source" "$lnd_conf_target"; then
        log_info "Arquivo '$lnd_conf_target' atualizado com a configuração '$new_state'."
    else
        log_error "Falha ao copiar '$lnd_conf_source' para '$lnd_conf_target'. Verifique permissões. Abortando troca."
        notify "🚨 ERRO Fallback: Falha ao copiar config '$new_state'."
        exit 1
    fi

    # Atualiza o arquivo de estado
    if echo "$new_state" > "$STATE_FILE"; then
        log_info "Arquivo de estado '$STATE_FILE' atualizado para '$new_state'."
    else
        log_error "Falha ao atualizar arquivo de estado '$STATE_FILE'. Verifique permissões."
        # Não aborta necessariamente, mas loga o erro.
    fi

    # Reinicia o LND via systemd
    log_info "Reiniciando LND (lnd.service)..."
    if systemctl restart --ignore-dependencies lnd.service; then
        log_info "LND reiniciado com sucesso usando configuração '$new_state'."
        notify "✅ LND Fallback: LND reiniciado com sucesso."
        exit 0 # Sai após a troca bem-sucedida
    else
        log_error "Falha ao reiniciar lnd.service! Verifique os logs do LND e do systemd."
        notify "🚨 ERRO Fallback: Falha ao reiniciar LND após trocar para '$new_state'!"
        exit 1 # Sai com erro se o LND não reiniciar
    fi

    sleep 5 # Aguarda um pouco antes de reiniciar os demais Serviços

    # Reinicia serviços dependentes individualmente, se existirem e estiverem ativos
    log_info "Verificando e reiniciando serviços dependentes..."

    local services_to_check=("lndg" "lndg-controller" "thunderhub" "bos-telegram")
    local restarted_services=()
    for service in "${services_to_check[@]}"; do
        if systemctl is-active --quiet "$service"; then
            log_info "Serviço '$service' está ativo. Tentando reiniciar..."
            if systemctl restart "$service"; then
                log_info "'$service' reiniciado com sucesso."
                restarted_services+=("$service")
            else
                log_error "Falha ao enviar comando de reinício para '$service'. Verifique os logs do systemd."
            fi
        else
            log_info "Serviço '$service' não encontrado ou não está ativo. Pulando reinício."
        fi
    done

    # Monta uma única mensagem com os serviços que foram reiniciados
    if [ ${#restarted_services[@]} -gt 0 ]; then
        notify "✅ LND Fallback: Serviços reiniciados: ${restarted_services[*]}"
    else
        notify "⚠️ LND Fallback: Nenhum serviço foi reiniciado (não estavam ativos ou não encontrados)."
    fi
}

# 4) Executa a verificação e decide se troca o estado
if check_bitcoin_connection; then
    # Conexão OK: Verifica se precisa voltar para o principal
    if [ "$CURRENT_STATE" != "principal" ]; then
        log_info "Conexão com node principal restaurada. Voltando para 'principal'."
        switch_state "principal"
    fi
else
    # Conexão Falhou: Verifica se precisa ir para o backup
    if [ "$CURRENT_STATE" != "backup" ]; then
        log_info "Conexão com node principal falhou. Trocando para 'backup'."
        switch_state "backup"
    fi
fi
exit 0
