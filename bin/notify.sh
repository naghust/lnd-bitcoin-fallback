#!/usr/bin/env bash
# notify.sh - Biblioteca para envio de notificações via Telegram
#
# Propósito:
#   Este script centraliza a lógica de comunicação com a API do Telegram.
#   Ele lê as configurações necessárias (token, chat_id, enabled) de um
#   arquivo config.ini localizado em um diretório ../config relativo ao script.
#
# Uso:
#   1. Como biblioteca: Use `source notify.sh` em outro script Bash.
#      Depois, chame a função `notify "Sua mensagem aqui"`.
#   2. Diretamente: Execute `./notify.sh "Sua mensagem aqui"`.
#
# Configuração (../config/config.ini):
#   [telegram]
#   enabled = true   # ou false para desabilitar
#   token = SEU_TOKEN_AQUI
#   chat_id = SEU_CHAT_ID_AQUI
#
# Dependências:
#   bash, coreutils, crudini, curl

# Habilita modos de erro estritos
set -euo pipefail

# --------------------------------------------------------------------------------
# Definição de cores ANSI para realce de mensagens (se terminal suportar)
# --------------------------------------------------------------------------------
if [ -t 1 ]; then # Verifica se a saída padrão é um terminal
    RED=\'\033[0;31m\'
    GREEN=\'\033[0;32m\'
    YELLOW=\'\033[1;33m\'
    CYAN=\'\033[1;36m\'
    NC=\'\033[0m\' # Sem cor (reset)
else
    RED=\'\'
    GREEN=\'\'
    YELLOW=\'\'
    CYAN=\'\'
    NC=\'\'
fi

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
CONFIG_FILE="$CONFIG_DIR/config.ini"

# --- Variáveis Globais de Configuração (carregadas por load_config) ---
declare NOTIFY_TOKEN=""
declare NOTIFY_CHATID=""
declare NOTIFY_ENABLED="false"
declare CONFIG_LOADED=0 # Flag para evitar recarregamento

# --------------------------------------------------------------------------------
# Função: log_stderr
# Escreve mensagens de erro/aviso para a saída de erro padrão.
# --------------------------------------------------------------------------------
log_stderr() {
    echo -e "$*" >&2
}

# --------------------------------------------------------------------------------
# Função: load_config
# Carrega token, chat_id e flag enabled de config.ini via crudini.
# Retorna 0 se sucesso, 1 se falha.
# --------------------------------------------------------------------------------
load_config() {
    # Só carrega uma vez
    if [ $CONFIG_LOADED -eq 1 ]; then
        return 0
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_stderr "${RED}❌ ERRO [notify.sh]: Arquivo de configuração 	'$CONFIG_FILE' não encontrado.${NC}"
        return 1
    fi

    # Lê valores do arquivo, tratando erros do crudini
    NOTIFY_TOKEN=$(crudini --get "$CONFIG_FILE" telegram token 2>/dev/null || echo "")
    NOTIFY_CHATID=$(crudini --get "$CONFIG_FILE" telegram chat_id 2>/dev/null || echo "")
    NOTIFY_ENABLED=$(crudini --get "$CONFIG_FILE" telegram enabled 2>/dev/null | tr '[:upper:]' '[:lower:]' || echo "false")

    # Valida se as variáveis essenciais foram carregadas (se enabled=true)
    if [ "$NOTIFY_ENABLED" == "true" ]; then
        if [ -z "$NOTIFY_TOKEN" ]; then
            log_stderr "${RED}❌ ERRO [notify.sh]: 	'token' não definido na seção [telegram] de 	'$CONFIG_FILE'.${NC}"
            return 1
        fi
        if [ -z "$NOTIFY_CHATID" ]; then
            log_stderr "${RED}❌ ERRO [notify.sh]: 	'chat_id' não definido na seção [telegram] de 	'$CONFIG_FILE'.${NC}"
            return 1
        fi
    fi

    CONFIG_LOADED=1
    return 0
}

# --------------------------------------------------------------------------------
# Função: notify
# Envia mensagem ao chat Telegram configurado.
# Parâmetros:
#   $* - Texto da mensagem (pode conter quebras de linha)
# Retorna 0 se sucesso ou desabilitado, 1 se falha no envio/configuração.
# --------------------------------------------------------------------------------
notify() {
    local msg
    msg="$*"

    # Carrega configurações, se falhar, retorna erro
    if ! load_config; then
        return 1
    fi

    # Se desabilitado, apenas loga e retorna sucesso
    if [ "$NOTIFY_ENABLED" != "true" ]; then
        log_stderr "${YELLOW}⚠️  [notify.sh]: Notificações Telegram desabilitadas em 	'$CONFIG_FILE'. Mensagem não enviada.${NC}"
        return 0
    fi

    # Verifica se token e chat_id estão definidos (redundante se load_config funcionou, mas seguro)
    if [ -z "$NOTIFY_TOKEN" ] || [ -z "$NOTIFY_CHATID" ]; then
        log_stderr "${RED}❌ ERRO [notify.sh]: Token ou Chat ID do Telegram não configurados corretamente.${NC}"
        return 1
    fi

    # Envia via curl, capturando o código de status HTTP e suprimindo a saída normal
    http_code=$(curl -s -w "%{http_code}" -o /dev/null -X POST "https://api.telegram.org/bot${NOTIFY_TOKEN}/sendMessage" \
        -d chat_id="${NOTIFY_CHATID}" \
        --data-urlencode "text=${msg}")

    # Verifica o código de status HTTP
    if [ "$http_code" -eq 200 ]; then
        echo -e "${GREEN}✅ [notify.sh]: Notificação enviada ao Telegram.${NC}" # Log para stdout
        return 0
    else
        log_stderr "${RED}❌ ERRO [notify.sh]: Falha ao enviar notificação para o Telegram. Código HTTP: $http_code.${NC}"
        return 1
    fi
}

# --------------------------------------------------------------------------------
# Execução direta: verifica argumentos e chama a função notify
# --------------------------------------------------------------------------------
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [ $# -lt 1 ]; then
        log_stderr "${CYAN}Uso: $0 <mensagem>${NC}"
        exit 1
    fi
    # Chama notify e sai com o código de retorno dela
    if notify "$*"; then
        exit 0
    else
        exit 1
    fi
fi

