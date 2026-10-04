# Gerenciador de Swap Linux

Menu em português para criar swap em disco, escolher a capacidade máxima e ajustar swappiness. Compatível com Linux usando Bash e util-linux; em Btrfs exige btrfs-progs com `btrfs filesystem mkswapfile`.

## Executar

```bash
curl -fL https://raw.githubusercontent.com/Niltonjuniornzx/swap/main/swap.sh -o swap.sh
sudo bash swap.sh
```

Ou configurar diretamente 8 GiB e swappiness 10:

```bash
sudo bash swap.sh configure 8 10
sudo bash swap.sh status
```

Outros comandos: `swappiness 10`, `enable`, `disable`, `remove`, `help`.

## Como funciona

- O tamanho define a capacidade máxima **deste arquivo**, em GiB. Outras swaps, inclusive zram, permanecem independentes e podem aumentar a capacidade total.
- Swappiness (0–200) ajusta a preferência relativa entre trocar páginas de memória e recuperar cache; não é porcentagem de RAM nem um gatilho exato de uso.
- Usa somente `/var/lib/swap-manager/swapfile`, com permissão 600, e mantém entrada própria em fstab.
- Ao redimensionar, cria e ativa o novo arquivo antes de desativar o antigo. Precisa de espaço para ambos; mantém pelo menos 1 GiB livre.
- Btrfs usa o comando próprio para criar arquivo sem holes/compressão e com NOCOW. Não inclua o arquivo em snapshots.
- Se swapoff falhar, o arquivo em uso é preservado. Desativar swap pode pressionar a RAM; não execute durante falta de memória.
- Não configura hibernação, limites por aplicativo, zram nem altera swaps de outros programas.
- Configuração persistente de swappiness em `/etc/sysctl.d/99-swap-manager.conf`; remoção restaura o valor anterior se não houve outra alteração.

Requer root para alterações. `status` e `help` podem ser executados sem sudo. Não precisa de systemd.
