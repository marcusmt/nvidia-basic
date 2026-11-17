# nvidia-basic &nbsp; [![bluebuild build badge](https://github.com/marcusmt/nvidia-basic/actions/workflows/build.yml/badge.svg)](https://github.com/marcusmt/nvidia-basic/actions/workflows/build.yml)

Fedora Kinoite (KDE atômico) com o driver aberto da NVIDIA (`nvidia-open`) e mais nada.
Cada pacote extra está em `recipes/recipe.yml`, com o motivo anotado.

- Base: `ghcr.io/blue-build/base-images/fedora-kinoite-nvidia-open`, Fedora 45
- Compilada todo dia pelo GitHub Actions e publicada em `ghcr.io/marcusmt/nvidia-basic`
- Apps por Flatpak (Flathub já habilitado), dev por distrobox/devcontainer

## Installation

> [!WARNING]  
> [This is an experimental feature](https://www.fedoraproject.org/wiki/Changes/OstreeNativeContainerStable), try at your own discretion.

Instale o [Fedora Kinoite](https://fedoraproject.org/atomic-desktops/kinoite/) oficial e depois mude pra esta imagem:

- First rebase to the unsigned image, to get the proper signing keys and policies installed:
  ```
  rpm-ostree rebase ostree-unverified-registry:ghcr.io/marcusmt/nvidia-basic:latest
  ```
- Reboot to complete the rebase:
  ```
  systemctl reboot
  ```
- Then rebase to the signed image, like so:
  ```
  rpm-ostree rebase ostree-image-signed:docker://ghcr.io/marcusmt/nvidia-basic:latest
  ```
- Reboot again to complete the installation
  ```
  systemctl reboot
  ```

The `latest` tag will automatically point to the latest build. That build will still always use the Fedora version specified in `recipe.yml`, so you won't get accidentally updated to the next major version.

## Secure Boot

Se estiver ativado, cadastre a chave dos módulos da NVIDIA e confirme na tela azul (MOK) do próximo boot:

```bash
sudo mokutil --import /etc/pki/akmods/certs/akmods-ublue.der
```

Se o arquivo tiver outro nome, `ls /etc/pki/akmods/certs/` mostra qual é. Pra conferir que o driver carregou: `lsmod | grep nvidia`.

## Enxugar

Lista os apps do menu e o pacote de onde cada um vem:

```bash
for f in /usr/share/applications/*.desktop; do
  grep -q '^NoDisplay=true' "$f" && continue
  pkg=$(rpm -qf --qf '%{NAME}' "$f" 2>/dev/null) || continue
  printf '%-30s %s\n' "$pkg" "$(grep -m1 '^Name=' "$f" | cut -d= -f2-)"
done | sort -u
```

O que não quiser vai no bloco `dnf` → `remove` da receita. Depois do commit e da compilação: `rpm-ostree upgrade` e reiniciar.

## Rollback

Escolha a entrada anterior no boot ou rode `rpm-ostree rollback`. Pra guardar uma versão boa: `sudo ostree admin pin 0`.

## ISO

If build on Fedora Atomic, you can generate an offline ISO with the instructions available [here](https://blue-build.org/how-to/generate-iso/#_top). These ISOs cannot unfortunately be distributed on GitHub for free due to large sizes, so for public projects something else has to be used for hosting.

## Verification

These images are signed with [Sigstore](https://www.sigstore.dev/)'s [cosign](https://github.com/sigstore/cosign). You can verify the signature by downloading the `cosign.pub` file from this repo and running the following command:

```bash
cosign verify --key cosign.pub ghcr.io/marcusmt/nvidia-basic
```
