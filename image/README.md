# Arborescence `image/`

Chaque fichier de `image/` est copié dans le rootfs de l'image en conservant son
chemin absolu :

```text
image/common/etc/default/keyboard  ->  /etc/default/keyboard
image/live/usr/local/bin/foo       ->  /usr/local/bin/foo
```

Les overlays sont appliqués dans cet ordre :

1. `common/` : commun aux images `live` et `install` ;
2. `install/` ou `live/` : spécifique à la cible, appliqué en dernier.

Un fichier placé dans `live/` ou `install/` remplace donc le même chemin fourni
par `common/` ou par un paquet Debian.

## Règles

- Les fichiers de `common/` doivent être identiques dans les deux images.
- Ne pas y mettre de configuration propre à une machine :
  `/etc/hostname`, `/etc/hosts`, `/etc/resolv.conf`, `/etc/machine-id`,
  `/etc/fstab`, `/var` ou `/home`. Ces éléments sont créés par
  `scripts/finalize-rootfs.sh` ou par l'installateur.
- Les chemins sensibles gérés par Docker (`/etc/hosts`, `/etc/hostname`,
  `/etc/resolv.conf`) ne doivent pas être copiés pendant le build : ils sont
  remplacés après l'export, dans `scripts/finalize-rootfs.sh`.
- Les permissions et les liens symboliques sont conservés par `COPY`.
- Ne pas mettre de secrets dans cette arborescence : le contenu est visible
  dans l'historique des couches Docker.

## Évolution ostree/bootc

Pour une image ostree/bootc, les valeurs par défaut de `/etc` sont souvent
placées dans `/usr/etc` et fusionnées par rpm-ostree ou bootc. Ubuntu 26.04 ne
fournit pas bootc, et `ostree` seul ne fusionne pas `/usr/etc` : tant que cette
logique n'est pas ajoutée, les configurations doivent rester dans `etc/` pour
être réellement appliquées.
