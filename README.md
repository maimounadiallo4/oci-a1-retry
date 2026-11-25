# oci-a1-retry

Workflow GitHub Actions qui crée automatiquement une VM **Always Free Ampere A1** sur Oracle Cloud (région Madrid) dès qu'une place se libère.

## Fonctionnement

- Toutes les heures, un run tente la création pendant environ 40 min (un essai par minute).
- Au premier passage, le script crée le réseau : VCN `vcn-a1`, Internet Gateway, route par défaut et sous-réseau public `subnet-a1`.
- Dès que la VM `vm-ubuntu-a1` est créée, le workflow ouvre une issue avec l'IP publique (notification par mail) puis se désactive.
- Si la VM existe déjà, le run s'arrête sans rien faire.

## Configuration

| Paramètre | Valeur par défaut | Où le changer |
|---|---|---|
| Shape | VM.Standard.A1.Flex | `scripts/create-a1.sh` |
| OCPU / RAM | 4 / 24 Go | `VM_OCPUS`, `VM_MEMORY_GB` dans le workflow |
| Disque | 100 Go | `VM_BOOT_GB` |
| Image | Ubuntu 24.04 aarch64 la plus récente | recherchée automatiquement |

## Secrets requis

`OCI_USER_OCID`, `OCI_TENANCY_OCID`, `OCI_FINGERPRINT`, `OCI_REGION`, `OCI_PRIVATE_KEY`, `SSH_PUBLIC_KEY`

---
Maïmouna DIALLO
