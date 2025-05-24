# Bitcoin/LND Fallback Script

Este projeto fornece um script Bash para monitorar a conexão com um node Bitcoin Core principal e, em caso de falha, automaticamente fazer fallback para um node Bitcoin Core de backup, ajustando a configuração do LND (Lightning Network Daemon) para apontar para o node ativo.

O teste de conexão com o node Bitcoin é feito via `curl`, **não sendo necessária a instalação do `bitcoin-cli`** na máquina onde o script é executado.

## Funcionalidades

*   **Verificação Periódica:** Utiliza um timer systemd para verificar a conectividade com o node Bitcoin principal a cada minuto (configurável).
*   **Fallback Automático:** Se o node principal falhar, o script atualiza a configuração do LND (`lnd.conf`) para usar as configurações do node de backup (`config/lnd.backup.conf`) e reinicia o LND e outros serviços necessários, se estiverem rodando (lndg, lndg-controller, thunderhub e bos-telegram).
*   **Retorno Automático:** Quando a conexão com o node principal é restaurada, o script reverte a configuração do LND para usar o node principal (`config/lnd.principal.conf`) e reinicia o LND e outros serviços necessários, se estiverem rodando (lndg, lndg-controller, thunderhub e bos-telegram).
*   **Gerenciamento de Estado:** Mantém o estado atual (usando node "principal" ou "backup") em um arquivo (`config/.fallback_state`) para evitar trocas desnecessárias.
*   **Notificações:** Envia notificações via Telegram sobre as trocas de estado e possíveis erros (configurável).
*   **Logging:** Registra as ações e erros em um arquivo de log (`lnd_fallback.log` por padrão, dentro do diretório LND definido em `config.ini`).

## Estrutura do Projeto

```
bitcoin-fallback/
├── bin/                  # Scripts executáveis
│   ├── bitcoin_fallback.sh
│   └── notify.sh
├── config/               # Arquivos de configuração
│   ├── config.ini.example       # Exemplo de configuração principal
│   # --- Arquivos a serem criados/copiados pelo usuário --- #
│   ├── config.ini             # Sua configuração principal
│   ├── lnd.principal.conf     # Sua config LND p/ node principal
│   ├── lnd.backup.conf      # Sua config LND p/ node backup
│   # --- Arquivos a serem criados/manipulados pelo script ---
│   └── .fallback_state        # Arquivo de estado
├── .gitignore            # Arquivos a serem ignorados pelo Git
├── LICENSE               # Licença do projeto (ex: MIT)
└── README.md             # Este arquivo
```

## Pré-requisitos e Dependências

*   **Sistema Operacional:** Linux com `systemd`.
*   **Interpretador:** `bash` (versão 4 ou superior recomendado).
*   **Utilitários Essenciais:** `coreutils` (geralmente pré-instalado, fornece `dirname`, `readlink`, `cp`, `echo`, `mkdir`, `tee`, `grep`).
*   **`crudini`:** Utilitário para ler/modificar arquivos `.ini`.
*   **`curl`:** Ferramenta para transferir dados com URLs (usada para teste de conexão RPC e notificações Telegram).
*   **`git`:** Utilitário de controle de versão distribuído, necessário para clonar este repositório e, opcionalmente, para versionar alterações locais.
*   **Acesso `sudo`:** Necessário para instalar dependências e os serviços systemd.
*   **Nodes Bitcoin:** Dois nodes Bitcoin Core (principal e backup) configurados e acessíveis via RPC pela máquina onde o script rodará.
*   **Node LND:** Um node LND instalado e configurado, com um arquivo `lnd.conf` funcional.

**Instalação das Dependências (Exemplo Debian/Ubuntu):**

```bash
sudo apt update
sudo apt install -y crudini curl coreutils bash git
```

## Instalação e Configuração

1.  **Clone o Repositório:**
    ```bash
    git clone https://github.com/naghust/lnd-bitcoin-fallback
    cd bitcoin-fallback
    ```

2.  **Torne os Scripts Executáveis:**
    ```bash
    chmod +x bin/bitcoin_fallback.sh bin/notify.sh
    ```

3.  **Copie o Exemplo de Configuração Principal:**
    ```bash
    cp config/config.ini.example config/config.ini
    ```

4.  **Edite `config/config.ini`:**
    *   Ajuste o `LND_DIR` na seção `[General]` para o diretório de dados do seu LND (onde seu `lnd.conf` atual reside).
    *   Na seção `[bitcoin_fallback]`, configure os detalhes de conexão para o seu **node Bitcoin principal**:
        *   `BITCOIN_RPC_HOST`: Defina como `127.0.0.1` se o node principal for local, ou o IP/hostname se for remoto.
        *   `BITCOIN_RPC_PORT`: Defina a porta RPC do node principal (ex: 8332 para mainnet).
        *   `BITCOIN_RPC_USER`: Defina o usuário RPC do node principal.
        *   `BITCOIN_RPC_PASS`: Defina a senha RPC do node principal.
    *   Se desejar notificações Telegram, configure a seção `[telegram]` com `enabled = true`, seu `token` e `chat_id`.

5.  **Defina permissões restritas para o arquivo config.ini:**
    ```bash
    sudo chmod 600 config/config.ini
    ```

6.  **Crie os Arquivos de Configuração do LND para Fallback:**
    *   Vá até o diretório de configuração do seu LND (o `LND_DIR` que você definiu no `config.ini`).
    *   **Copie seu `lnd.conf` atual** duas vezes, dentro do diretório `config/` do projeto `lnd-bitcoin-fallback`:
        ```bash
        # Exemplo: Se LND_DIR=/data/lnd e o projeto está em /home/admin/lnd-bitcoin-fallback
        cp /data/lnd/lnd.conf /home/admin/lnd-bitcoin-fallback/config/lnd.principal.conf
        cp /data/lnd/lnd.conf /home/admin/lnd-bitcoin-fallback/config/lnd.backup.conf
        ```
    *   **Edite `config/lnd.principal.conf` e `config/lnd.backup.conf`:** Modifique **APENAS** a seção `[Bitcoind]` para apontar para cada um dos nodes. Use o formato apropriado (local ou remoto) para as linhas relevantes:
        ```ini
        [Bitcoind]
        # Para node LOCAL (descomente as 3 linhas abaixo e comente as 3 linhas de 'Para node REMOTO'):
        # bitcoind.rpchost=127.0.0.1:8332 
        # bitcoind.zmqpubrawblock=tcp://127.0.0.1:28332
        # bitcoind.zmqpubrawtx=tcp://127.0.0.1:28333
        
        # Para node REMOTO  (descomente as 3 linhas abaixo e comente as 3 linhas de 'Para node LOCAL'):
        bitcoind.rpchost=IP_OU_HOSTNAME_DO_NODE_PRINCIPAL:PORTA_RPC_PRINCIPAL
        bitcoind.zmqpubrawblock=tcp://IP_OU_HOSTNAME_DO_NODE_PRINCIPAL:PORTA_ZMQ_BLOCK
        bitcoind.zmqpubrawtx=tcp://IP_OU_HOSTNAME_DO_NODE_PRINCIPAL:PORTA_ZMQ_TX
        
        # Credenciais (sempre necessárias):
        bitcoind.rpcuser=USUARIO_RPC_PRINCIPAL
        bitcoind.rpcpass=SENHA_RPC_PRINCIPAL
        ```
    *   **Edite `config/lnd.backup.conf`:** Modifique **APENAS** a seção `[Bitcoind]` para apontar para o seu **node Bitcoin de backup**, usando o mesmo formato (local ou remoto) conforme necessário:so.

7.  **Instale os Serviços Systemd:**
    *   **Crie o arquivo do Serviço:**
        ```bash
        sudo nano /etc/systemd/system/bitcoin-fallback-check.service
        ```
    *   **Copie o texto a seguir e cole no arquivo (salve e saia do arquivo - Ctrl+X, y, Enter):**
        ```bash
        [Unit]
        Description=Bitcoin Fallback Check
        After=bitcoind.service

        [Service]
        Type=oneshot
	# Informe o caminho correto para o script na linha abaixo
        ExecStart=/home/admin/lnd-bitcoin_fallback/bin/bitcoin_fallback.sh
        ```
    *   **Crie o arquivo do serviço:**
        ```bash
        sudo nano /etc/systemd/system/bitcoin-fallback-check.timer
        ```
    *   **Copie o texto a seguir e cole no arquivo (salve e saia do arquivo - Ctrl+X, y, Enter):**
        ```bash
        [Unit]
        Description=Run Bitcoin Fallback Check every 1 minute

        [Timer]
        OnBootSec=1min
        OnUnitActiveSec=1min
        AccuracySec=1s

        [Install]
        WantedBy=timers.target
        ```
    *   **Recarregue o Systemd:**
        ```bash
        sudo systemctl daemon-reload
        ```
    *   **Habilite e Inicie o Timer:**
        ```bash
        sudo systemctl enable --now bitcoin-fallback-check.timer
        ```

8.  **Verifique o Status:**
    *   Verifique se o timer está ativo:
        ```bash
        systemctl status bitcoin-fallback-check.timer
        ```
    *   Verifique os logs do serviço após um minuto:
        ```bash
        journalctl -u bitcoin-fallback-check.service -f
        ```
    *   Verifique o log do script (o caminho exato depende do seu `LND_DIR`):
        ```bash
        tail -f $(crudini --get config/config.ini General LND_DIR)/lnd_fallback.log
        ```

## Funcionamento

1.  O `bitcoin-fallback-check.timer` ativa o `bitcoin-fallback-check.service` a cada minuto.
2.  O serviço executa o script `bin/bitcoin_fallback.sh`.
3.  O script lê o estado atual (`principal` ou `backup`) do arquivo `config/.fallback_state`.
4.  Tenta conectar ao node Bitcoin principal usando `curl` para enviar uma requisição JSON-RPC (`getblockchaininfo`) com os detalhes (`BITCOIN_RPC_HOST`, `BITCOIN_RPC_PORT`, `BITCOIN_RPC_USER`, `BITCOIN_RPC_PASS`) da seção `[bitcoin_fallback]` em `config/config.ini`.
5.  **Se a conexão RPC via `curl` for bem-sucedida:**
    *   Se o estado atual for `backup`, ele inicia a troca para `principal`:
        *   Copia `config/lnd.principal.conf` para o `lnd.conf` ativo (localizado em `LND_DIR`).
        *   Atualiza `config/.fallback_state` para `principal`.
        *   Envia notificação (se habilitado).
        *   Reinicia o serviço `lnd.service`.
        *   Reinicia serviços dependentes se estiverem rodando (lndg, lndg-controller, thunderhub e bos-telegram).
    *   Se o estado atual já for `principal`, nenhuma ação é tomada.
6.  **Se a conexão RPC via `curl` falhar (timeout, erro de conexão/auth, resposta inválida):**
    *   Se o estado atual for `principal`, ele inicia a troca para `backup`:
        *   Copia `config/lnd.backup.conf` para o `lnd.conf` ativo.
        *   Atualiza `config/.fallback_state` para `backup`.
        *   Envia notificação (se habilitado).
        *   Reinicia o serviço `lnd.service`.
        *   Reinicia serviços dependentes se estiverem rodando (lndg, lndg-controller, thunderhub e bos-telegram).
    *   Se o estado atual já for `backup`, nenhuma ação é tomada.

## Licença

Este projeto é distribuído sob a licença MIT. Veja o arquivo `LICENSE` para mais detalhes.

## Contribuições

Contribuições são bem-vindas! Sinta-se à vontade para abrir issues ou pull requests.

