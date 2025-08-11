#!/bin/bash

# Parâmetros fixos iniciais (pode alterar se quiser)
mesh_url="https://mesh.faciniinformatica.com.br/meshagents"
rmm_url="https://api.faciniinformatica.com.br"
rmm_client_id="1"
rmm_site_id="49"
rmm_auth="67d801a9fe99870e32eb94b76a261833168b5aae582c04c870066605e20a62ea"
rmm_agent_type="server"  # valor default, pode ser alterado na instalação

function show_help() {
    echo "Uso: $0 {install|update|uninstall|help}"
    echo ""
    echo "Comandos:"
    echo "  install   Instala o Tactical RMM Agent (pergunta descrição e tipo do agente)"
    echo "  update    Atualiza o Tactical RMM Agent"
    echo "  uninstall Remove o Tactical RMM Agent"
    echo "  help      Mostra esta ajuda"
    echo ""
}

# Se nenhum argumento for passado, executa install por padrão
if [[ $# -eq 0 ]]; then
    echo "Nenhum parâmetro informado, executando instalação por padrão..."
    set -- install
fi

case $1 in
    help)
        show_help
        exit 0
        ;;
    install)
        ;;
    update)
        ;;
    uninstall)
        ;;
    *)
        echo "Comando inválido!"
        show_help
        exit 1
        ;;
esac

## Detectar arquitetura
system=$(uname -m)
case $system in
    x86_64)
        system="amd64"
        ;;
    i386|i686)
        system="x86"
        ;;
    aarch64)
        system="arm64"
        ;;
    armv6l)
        system="armv6"
        ;;
    *)
        echo "Arquitetura não suportada: $system"
        exit 1
        ;;
esac

## Instalar Go (se necessário)
function go_install() {
    if ! command -v go &> /dev/null; then
        echo "[+] Instalando Go..."
        case $system in
            amd64) url="https://go.dev/dl/go1.21.6.linux-amd64.tar.gz" ;;
            x86) url="https://go.dev/dl/go1.21.6.linux-386.tar.gz" ;;
            arm64) url="https://go.dev/dl/go1.21.6.linux-arm64.tar.gz" ;;
            armv6) url="https://go.dev/dl/go1.21.6.linux-armv6l.tar.gz" ;;
        esac
        wget -q -O /tmp/golang.tar.gz "$url"
        sudo rm -rf /usr/local/go
        sudo tar -C /usr/local -xzf /tmp/golang.tar.gz
        rm /tmp/golang.tar.gz
        export PATH=$PATH:/usr/local/go/bin
        echo "Go instalado."
    else
        echo "Go já instalado."
    fi
}

## Compilar agente
function agent_compile() {
    echo "[+] Compilando agente Tactical RMM..."
    wget -q -O /tmp/rmmagent.tar.gz "https://github.com/amidaware/rmmagent/archive/refs/heads/master.tar.gz"
    tar -xf /tmp/rmmagent.tar.gz -C /tmp/
    rm /tmp/rmmagent.tar.gz
    cd /tmp/rmmagent-master || exit 1
    case $system in
        amd64) env CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        x86) env CGO_ENABLED=0 GOOS=linux GOARCH=386 go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        arm64) env CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
        armv6) env CGO_ENABLED=0 GOOS=linux GOARCH=arm go build -ldflags "-s -w" -o /tmp/temp_rmmagent ;;
    esac
    cd /tmp || exit 1
    rm -rf /tmp/rmmagent-master
    echo "[+] Compilação concluída."
}

## Atualizar agente
function update_agent() {
    echo "[+] Parando serviço tacticalagent..."
    sudo systemctl stop tacticalagent || true

    echo "[+] Copiando novo binário..."
    sudo cp /tmp/temp_rmmagent /usr/local/bin/rmmagent
    sudo chmod +x /usr/local/bin/rmmagent
    rm /tmp/temp_rmmagent

    echo "[+] Reiniciando serviço tacticalagent..."
    sudo systemctl start tacticalagent
}

## Instalar agente
function install_agent() {
    echo "[+] Copiando binário compilado..."
    sudo cp /tmp/temp_rmmagent /usr/local/bin/rmmagent
    sudo chmod +x /usr/local/bin/rmmagent

    # Pergunta descrição
    read -p "Digite a descrição do dispositivo (ex: Servidor DB01): " device_desc
    if [[ -z "$device_desc" ]]; then
        device_desc=$(hostname)
        echo "Descrição vazia. Usando hostname: $device_desc"
    fi

    # Pergunta tipo do agente com validação
    while true; do
        read -p "Tipo do agente (server/workstation) [server]: " agent_type_input
        agent_type_input=${agent_type_input,,}  # para minúsculo
        if [[ -z "$agent_type_input" ]]; then
            rmm_agent_type="server"
            break
        elif [[ "$agent_type_input" == "server" || "$agent_type_input" == "workstation" ]]; then
            rmm_agent_type="$agent_type_input"
            break
        else
            echo "Entrada inválida. Digite 'server' ou 'workstation'."
        fi
    done

    echo "[+] Registrando agente no servidor Tactical RMM com descrição: $device_desc e tipo: $rmm_agent_type ..."
    sudo /usr/local/bin/rmmagent -m install \
      -api "$rmm_url" \
      -client-id "$rmm_client_id" \
      -site-id "$rmm_site_id" \
      -agent-type "$rmm_agent_type" \
      -auth "$rmm_auth" \
      --desc "$device_desc"

    rm /tmp/temp_rmmagent

    echo "[+] Criando serviço systemd tacticalagent..."
    sudo tee /etc/systemd/system/tacticalagent.service > /dev/null <<EOL
[Unit]
Description=Tactical RMM Linux Agent
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rmmagent -m svc
User=root
Group=root
Restart=always
RestartSec=5s
LimitNOFILE=1000000
KillMode=process

[Install]
WantedBy=multi-user.target
EOL

    echo "[+] Recarregando systemd e habilitando serviço..."
    sudo systemctl daemon-reload
    sudo systemctl enable tacticalagent
    sudo systemctl start tacticalagent
    echo "[✔] Instalação concluída e serviço iniciado."
}

## Desinstalar agente
function uninstall_agent() {
    echo "[+] Parando serviço tacticalagent..."
    sudo systemctl stop tacticalagent || true
    sudo systemctl disable tacticalagent || true

    echo "[+] Removendo arquivos..."
    sudo rm /etc/systemd/system/tacticalagent.service
    sudo rm /usr/local/bin/rmmagent
    sudo systemctl daemon-reload
    echo "[✔] Agente desinstalado."
}

case $1 in
    install)
        go_install
        agent_compile
        install_agent
        ;;
    update)
        go_install
        agent_compile
        update_agent
        ;;
    uninstall)
        uninstall_agent
        ;;
esac
