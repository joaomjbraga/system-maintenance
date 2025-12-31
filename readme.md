# system-maintenance

**Script de manutenção de sistema para produção em Debian/Ubuntu Linux**

---

## Visão Geral

**system-maintenance** automatiza a limpeza e otimização abrangente do sistema para distribuições Linux baseadas em Debian. Projetado para confiabilidade em ambientes de produção com tratamento robusto de erros, registro abrangente e operação não-interativa adequada para automação.

**Recursos:**
- Não-interativo por padrão (pronto para cron/CI)
- Modo de simulação (dry-run) abrangente
- Registro estruturado com rastreamento de erros
- Backup de pacotes antes das operações
- Detecção de ambiente (container, WSL, desktop, servidor)
- Configurável via flags CLI
- Operação segura com validação extensiva de entrada

**Testado em:** Pop!_OS, Ubuntu, Debian

---

## O Que Ele Faz

O script executa 11 operações de manutenção:

1. **Listas de Pacotes** - Atualiza o banco de dados de pacotes APT
2. **Pacotes Não Utilizados** - Remove pacotes e dependências (`apt autoremove`)
3. **Cache APT** - Limpa o cache do gerenciador de pacotes (`apt clean`, `autoclean`)
4. **Pacotes Órfãos** - Remove pacotes órfãos via deborphan
5. **Configurações Residuais** - Purga arquivos de configuração de pacotes removidos
6. **Flatpak** - Remove apps Flatpak não utilizados e repara instalações
7. **Snap** - Remove revisões de snap desabilitadas
8. **Logs do Sistema** - Limpa logs do journal (limite de 7 dias ou 100MB)
9. **Caches de Usuário** - Limpa `~/.cache` e miniaturas (arquivos com mais de 30 dias)
10. **Arquivos Temporários** - Remove arquivos antigos de `/tmp` e `/var/tmp`
11. **Caches Diversos** - Limpa cache man, pip, npm e atualiza banco de dados locate

---

## Instalação

### Requisitos

- Sistema baseado em Debian/Ubuntu
- Acesso root (sudo)
- Bash 4.0+
- Conexão com internet (recomendado)

### Configuração

```bash
# Clonar repositório
git clone https://github.com/joaomjbraga/system-maintenance.git
cd system-maintenance

# Tornar executável
chmod +x system-maintenance.sh

# Executar primeiro com dry-run
sudo ./system-maintenance.sh --dry-run
```

---

## Uso

### Uso Básico

```bash
# Manutenção completa
sudo ./system-maintenance.sh

# Visualizar sem fazer alterações
sudo ./system-maintenance.sh --dry-run

# Modo interativo (confirmações)
sudo ./system-maintenance.sh --interactive

# Modo silencioso (apenas logs)
sudo ./system-maintenance.sh --quiet
```

### Opções Avançadas

```bash
# Pular operações específicas
sudo ./system-maintenance.sh --no-flatpak --no-snap

# Pular limpeza de logs (recomendado para servidores)
sudo ./system-maintenance.sh --no-logs

# Forçar reinicialização automática
sudo ./system-maintenance.sh --force-reboot

# Combinação
sudo ./system-maintenance.sh --dry-run --no-snap --interactive
```

### Flags CLI

| Flag | Descrição |
|------|-----------|
| `-d, --dry-run` | Simula ações sem fazer alterações |
| `-i, --interactive` | Solicita confirmação antes das operações |
| `-q, --quiet` | Suprime saída do console (apenas arquivo de log) |
| `--no-flatpak` | Pula manutenção do Flatpak |
| `--no-snap` | Pula manutenção do Snap |
| `--no-logs` | Pula limpeza de logs do sistema |
| `--force-reboot` | Reinicia automaticamente após conclusão |
| `-h, --help` | Mostra mensagem de ajuda |
| `-v, --version` | Mostra informações de versão |

### Automação

**Cron (manutenção mensal):**
```bash
# Editar crontab
sudo crontab -e

# Adicionar linha (executa às 3h no primeiro dia do mês)
0 3 1 * * /caminho/para/system-maintenance.sh --quiet --no-logs >> /var/log/system-maintenance/cron.log 2>&1
```

**Timer Systemd:**
```ini
# /etc/systemd/system/system-maintenance.timer
[Unit]
Description=Manutenção mensal do sistema

[Timer]
OnCalendar=monthly
Persistent=true

[Install]
WantedBy=timers.target
```

```ini
# /etc/systemd/system/system-maintenance.service
[Unit]
Description=Script de manutenção do sistema

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-maintenance.sh --quiet
```

```bash
# Habilitar e iniciar
sudo systemctl enable --now system-maintenance.timer
```

---

## Registro de Logs

Todas as operações são registradas em:
```
/var/log/system-maintenance/run_AAAAMMDD_HHMMSS.log
```

**Formato do log:**
```
[2025-01-15 14:30:22] [INFO] Iniciando manutenção do sistema (versão 3.0.0)
[2025-01-15 14:30:23] [OK] Validação de ambiente passou
[2025-01-15 14:30:25] [OK] Lista de pacotes com backup
[2025-01-15 14:30:30] [WARN] Sem conectividade com internet detectada
[2025-01-15 14:35:45] [ERROR] Operação falhou (código de saída: 1)
```

**Análise de logs:**
```bash
# Verificar erros
grep ERROR /var/log/system-maintenance/*.log

# Ver última execução
ls -t /var/log/system-maintenance/*.log | head -1 | xargs cat

# Monitorar em tempo real
tail -f /var/log/system-maintenance/run_*.log
```

---

## Exemplo de Saída

```
→ Validando ambiente...
✓ Validação de ambiente passou
→ Criando backup de pacotes...
✓ Lista de pacotes salva em: /var/backups/system-maintenance/packages_20250115_143022.txt
→ Atualizando listas de pacotes...
✓ apt update
→ Verificando pacotes não utilizados...
→ Encontrados 8 pacotes não utilizados
✓ Remover pacotes não utilizados
→ Limpando cache APT...
✓ Cache APT limpo (liberado 245MB)
→ Verificando pacotes órfãos...
✓ Nenhum pacote órfão encontrado
...

═══════════════════════════════════════════════════════════
RELATÓRIO DE MANUTENÇÃO
═══════════════════════════════════════════════════════════

  Espaço antes:       15GB
  Espaço depois:      18GB
  Espaço liberado:    3GB

  Pacotes removidos:  8
  Órfãos removidos:   0
  Cache limpo:        245MB
  Erros:              0

  Arquivo de log:     /var/log/system-maintenance/run_20250115_143022.log
═══════════════════════════════════════════════════════════
```

---

## Configuração

Edite as constantes no início do script:

```bash
# Retenção de cache
readonly CACHE_AGE_DAYS=30           # Idade dos arquivos de cache do usuário

# Retenção de arquivos temporários
readonly TMP_AGE_DAYS=2              # Idade dos arquivos em /tmp

# Retenção de logs
readonly LOG_RETENTION_DAYS=7        # Retenção de logs do sistema
readonly LOG_MAX_SIZE="100M"         # Tamanho máximo do journal

# Segurança
readonly MIN_REQUIRED_SPACE_GB=5     # Espaço livre mínimo para prosseguir

# Diretórios
readonly LOG_DIR="/var/log/system-maintenance"
readonly BACKUP_DIR="/var/backups/system-maintenance"
```

---

## Segurança

**Proteções integradas:**
- ✅ Verificação de privilégios root
- ✅ Backup automático da lista de pacotes
- ✅ `set -euo pipefail` para tratamento robusto de erros
- ✅ Handlers `trap` para limpeza e registro de erros
- ✅ Validação de caminho em `safe_remove()` (bloqueia `/`, `/home`, `/root`)
- ✅ Detecção de bloqueio dpkg com timeout
- ✅ Requisito de espaço mínimo em disco
- ✅ Detecção de ambiente (pula operações em containers)
- ✅ Modo dry-run para testes
- ✅ Todas as operações destrutivas são registradas
- ✅ Falhas não-críticas não abortam o script
- ✅ Verificações de existência de comando antes da execução

**Local do backup:**
```
/var/backups/system-maintenance/packages_AAAAMMDD_HHMMSS.txt
```

**Restaurar pacotes do backup:**
```bash
sudo dpkg --set-selections < /var/backups/system-maintenance/packages_20250115.txt
sudo apt-get dselect-upgrade
```

---

## Uso em Produção

### Checklist Pré-implantação

1. **Testar em ambiente não-produção primeiro**
   ```bash
   sudo ./system-maintenance.sh --dry-run
   ```

2. **Revisar logs após execução de teste**
   ```bash
   cat /var/log/system-maintenance/run_*.log
   ```

3. **Ajustar flags para seu ambiente**
   - Servidores: `--no-logs` (preserva logs de aplicação)
   - Desktop: flags padrão
   - Containers: detecção automática, operações limitadas

4. **Configurar monitoramento**
   ```bash
   # Alertar em caso de erros
   grep -q ERROR /var/log/system-maintenance/*.log && notificar-admin
   ```

### Considerações para Servidores

**Flags recomendadas:**
```bash
sudo ./system-maintenance.sh --quiet --no-logs
```

**Por que `--no-logs`?**
- Preserva logs de aplicação
- Previne remoção acidental de trilhas de auditoria
- Limpeza do journal pode ser muito agressiva para produção

**Gerenciamento alternativo de logs:**
```bash
# Limpeza manual do journal (mais conservadora)
sudo journalctl --vacuum-time=30d
```

### Integração CI/CD

```yaml
# Exemplo GitLab CI
manutencao:
  stage: deploy
  script:
    - sudo /usr/local/bin/system-maintenance.sh --quiet --dry-run
  rules:
    - if: $CI_PIPELINE_SOURCE == "schedule"
  tags:
    - maintenance
```

---

## Solução de Problemas

**Script falha com erro "dpkg lock":**
```bash
# Aguardar conclusão de outras operações de pacote
# Script automaticamente aguarda até 5 minutos
```

**Aviso de espaço em disco baixo:**
```bash
# Verificar uso atual
df -h /

# Revisar o que está usando espaço
sudo du -sh /* | sort -h
```

**Erros no arquivo de log:**
```bash
# Verificar contagem de erros
grep -c ERROR /var/log/system-maintenance/*.log

# Ver erros específicos
grep ERROR /var/log/system-maintenance/*.log

# A maioria dos erros são não-críticos e registrados para auditoria
```

**Deborphan não instalado:**
```bash
# Script instala automaticamente se necessário
# Ou instalar manualmente:
sudo apt install deborphan
```

---

## Detecção de Ambiente

O script detecta e se adapta a:

| Ambiente | Comportamento |
|----------|---------------|
| **Container** | Pula prompts de reinicialização, operações de log limitadas |
| **WSL** | Operações padrão, consciente do WSL |
| **Desktop** | Conjunto completo de recursos |
| **Servidor** | Operações padrão, uso de `--no-logs` recomendado |

---

## Limitações

**Não realizado:**
- ❌ Remoção de kernels antigos (lógica específica da distro necessária)
- ❌ Verificação de integridade de pacotes
- ❌ Rollback automático em caso de falha
- ❌ Limpeza de cache de aplicações personalizadas

**Soluções alternativas:**

```bash
# Remover kernels antigos (Ubuntu/Debian)
sudo apt autoremove --purge

# Verificar integridade de pacotes
sudo debsums -c

# Cache de app personalizado (exemplo: Docker)
docker system prune -a
```

---

## Contribuindo

Contribuições são bem-vindas! Áreas para melhoria:

- [ ] Suporte multi-distro (Fedora, Arch)
- [ ] Lógica de limpeza de kernel
- [ ] Saída de relatório HTML/JSON
- [ ] Whitelist para pacotes críticos
- [ ] Flag de limite máximo de remoção (`--max-remove N`)
- [ ] Notificações por email/webhook
- [ ] Suporte a arquivo de configuração

**Processo de contribuição:**
1. Fork do repositório
2. Criar branch de feature (`git checkout -b feature/descricao`)
3. Commit das alterações (`git commit -m 'Adicionar feature'`)
4. Push para o branch (`git push origin feature/descricao`)
5. Abrir Pull Request

---

## Histórico de Versões

### Versão 3.0.0 (Atual)

**Refatoração maior:**
- Reescrita completa para confiabilidade em produção
- Não-interativo por padrão
- Flags CLI abrangentes
- Registro estruturado com rastreamento de erros
- Detecção de ambiente
- Tratamento de erros melhorado com trap
- Validação de caminho em safe_remove
- Tratamento de bloqueio dpkg com timeout
- Rastreamento de métricas e relatórios detalhados
- Modo dry-run
- Rotação automática de backup de pacotes
- Detecção de Container/WSL

### Versão 2.1

- Melhorias no tratamento de erros
- Sistema de registro completo
- Backup automático de pacotes
- Verificação de conectividade com internet
- Limpeza de cache multi-usuário
- Suporte a cache pip/npm

### Versão 2.0

- Redesign da interface visual
- Relatório de espaço liberado
- Estatísticas detalhadas

### Versão 1.0

- Lançamento inicial

---

## Licença

Licença MIT - Veja o arquivo [LICENSE](LICENSE) para detalhes.

---

## Autor

**João M J Braga**

- GitHub: [@joaomjbraga](https://github.com/joaomjbraga)
- Projeto: [system-maintenance](https://github.com/joaomjbraga/system-maintenance)

---

## Agradecimentos

Originalmente desenvolvido como **FlatTrash** v2.1, refatorado para padrões de nível de produção na v3.0.0.


**Mantenha seu sistema Linux otimizado e sustentável.**
