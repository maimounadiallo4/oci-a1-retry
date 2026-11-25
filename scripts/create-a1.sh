#!/usr/bin/env bash
# Tente de creer une VM Always Free Ampere A1 sur OCI, en boucle,
# jusqu'a ce que la capacite soit disponible ou que le temps imparti soit ecoule.
set -euo pipefail

C="${OCI_COMPARTMENT_ID:?OCI_COMPARTMENT_ID manquant}"
NAME="${VM_NAME:-vm-ubuntu-a1}"
OCPUS="${VM_OCPUS:-4}"
MEM="${VM_MEMORY_GB:-24}"
BOOT_GB="${VM_BOOT_GB:-100}"
SSH_KEY_FILE="${SSH_KEY_FILE:?SSH_KEY_FILE manquant}"
RUN_MINUTES="${RUN_MINUTES:-50}"
SLEEP_SECONDS="${SLEEP_SECONDS:-60}"

out_file="${GITHUB_OUTPUT:-/dev/null}"
log() { echo "[$(date -u +%H:%M:%S)] $*"; }

# Renvoie une chaine vide si la requete ne trouve rien
q() { oci "$@" 2>/dev/null || true; }

# 1. La VM existe deja ? Alors rien a faire.
existing=$(q compute instance list -c "$C" --display-name "$NAME" \
  --query "data[?\"lifecycle-state\"!='TERMINATED'] | [0].id" --raw-output)
if [[ -n "$existing" && "$existing" != "null" ]]; then
  log "La VM $NAME existe deja ($existing). Rien a faire."
  echo "created=false" >> "$out_file"
  echo "already=true" >> "$out_file"
  exit 0
fi

# 2. Reseau : VCN + Internet Gateway + route + sous-reseau public (crees une seule fois)
vcn=$(q network vcn list -c "$C" --display-name vcn-a1 --lifecycle-state AVAILABLE \
  --query "data[0].id" --raw-output)
if [[ -z "$vcn" || "$vcn" == "null" ]]; then
  log "Creation du VCN vcn-a1"
  vcn=$(oci network vcn create -c "$C" --display-name vcn-a1 --dns-label vcna1 \
    --cidr-blocks '["10.0.0.0/16"]' --wait-for-state AVAILABLE \
    --query data.id --raw-output)
fi

igw=$(q network internet-gateway list -c "$C" --vcn-id "$vcn" \
  --query "data[0].id" --raw-output)
if [[ -z "$igw" || "$igw" == "null" ]]; then
  log "Creation de l'Internet Gateway"
  igw=$(oci network internet-gateway create -c "$C" --vcn-id "$vcn" \
    --display-name igw-a1 --is-enabled true --wait-for-state AVAILABLE \
    --query data.id --raw-output)
  rt=$(oci network vcn get --vcn-id "$vcn" \
    --query 'data."default-route-table-id"' --raw-output)
  oci network route-table update --rt-id "$rt" --force \
    --route-rules "[{\"destination\":\"0.0.0.0/0\",\"destinationType\":\"CIDR_BLOCK\",\"networkEntityId\":\"$igw\"}]" \
    > /dev/null
fi

subnet=$(q network subnet list -c "$C" --vcn-id "$vcn" --display-name subnet-a1 \
  --query "data[0].id" --raw-output)
if [[ -z "$subnet" || "$subnet" == "null" ]]; then
  log "Creation du sous-reseau public subnet-a1"
  subnet=$(oci network subnet create -c "$C" --vcn-id "$vcn" \
    --display-name subnet-a1 --dns-label subneta1 --cidr-block 10.0.0.0/24 \
    --wait-for-state AVAILABLE --query data.id --raw-output)
fi

# 3. Image Ubuntu 24.04 compatible A1 (la plus recente) et domaine de disponibilite
image=$(oci compute image list -c "$C" --operating-system "Canonical Ubuntu" \
  --operating-system-version "24.04" --shape VM.Standard.A1.Flex \
  --sort-by TIMECREATED --sort-order DESC --limit 1 \
  --query "data[0].id" --raw-output)
ad=$(oci iam availability-domain list -c "$C" --query "data[0].name" --raw-output)
log "Image : $image"
log "AD    : $ad"

# 4. Boucle de tentatives
deadline=$(( $(date +%s) + RUN_MINUTES * 60 ))
attempt=0
while (( $(date +%s) < deadline )); do
  attempt=$((attempt + 1))
  log "Tentative $attempt ($OCPUS OCPU / $MEM Go)"
  set +e
  res=$(oci compute instance launch -c "$C" --availability-domain "$ad" \
    --display-name "$NAME" --shape VM.Standard.A1.Flex \
    --shape-config "{\"ocpus\":$OCPUS,\"memoryInGBs\":$MEM}" \
    --image-id "$image" --subnet-id "$subnet" --assign-public-ip true \
    --boot-volume-size-in-gbs "$BOOT_GB" \
    --ssh-authorized-keys-file "$SSH_KEY_FILE" \
    --wait-for-state RUNNING --max-wait-seconds 900 \
    --query data.id --raw-output 2>&1)
  rc=$?
  set -e

  if (( rc == 0 )); then
    id=$(echo "$res" | grep -o 'ocid1\.instance[^" ]*' | head -n1)
    ip=$(oci compute instance list-vnics --instance-id "$id" \
      --query 'data[0]."public-ip"' --raw-output)
    log "VM creee : $id, IP publique $ip"
    {
      echo "created=true"
      echo "instance_id=$id"
      echo "public_ip=$ip"
    } >> "$out_file"
    exit 0
  fi

  if grep -qi "capacity" <<< "$res"; then
    log "Pas de capacite, nouvel essai dans ${SLEEP_SECONDS}s"
    sleep "$SLEEP_SECONDS"
  elif grep -qiE "TooManyRequests|429" <<< "$res"; then
    log "Trop de requetes, pause de 3 min"
    sleep 180
  else
    log "Erreur inattendue :"
    echo "$res"
    exit 1
  fi
done

log "Temps ecoule sans capacite. Prochain essai au prochain declenchement."
echo "created=false" >> "$out_file"
