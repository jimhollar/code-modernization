#!/bin/bash

SUBSCRIPTION_ID=""
LOCATION=""
MODELS_PARAMETER=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --SubscriptionId)
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --Location)
      LOCATION="$2"
      shift 2
      ;;
    --ModelsParameter)
      MODELS_PARAMETER="$2"
      shift 2
      ;;
    *)
      echo "❌ ERROR: Unknown option: $1"
      exit 1
      ;;
  esac
done

# Validate required parameters
MISSING_PARAMS=()
[[ -z "$SUBSCRIPTION_ID" ]] && MISSING_PARAMS+=("SubscriptionId")
[[ -z "$LOCATION" ]] && MISSING_PARAMS+=("Location")
[[ -z "$MODELS_PARAMETER" ]] && MISSING_PARAMS+=("ModelsParameter")

if [[ ${#MISSING_PARAMS[@]} -ne 0 ]]; then
  echo "❌ ERROR: Missing required parameters: ${MISSING_PARAMS[*]}"
  echo "Usage: $0 --SubscriptionId <SUBSCRIPTION_ID> --Location <LOCATION> --ModelsParameter <MODELS_PARAMETER>"
  exit 1
fi

# Read from environment
AISERVICE_NAME="${AZURE_AISERVICE_NAME}"
RESOURCE_GROUP="${AZURE_RESOURCE_GROUP}"

# Check service and deployment existence
if [[ -n "$AISERVICE_NAME" && -n "$RESOURCE_GROUP" ]]; then
  existing=$(az cognitiveservices account show --name "$AISERVICE_NAME" --resource-group "$RESOURCE_GROUP" --query "name" --output tsv 2>/dev/null)
  if [[ -n "$existing" ]]; then
    echo "ℹ️ Found Azure AI service: $AISERVICE_NAME"

    existing_deployments=$(az cognitiveservices account deployment list --name "$AISERVICE_NAME" --resource-group "$RESOURCE_GROUP" --query "[].name" --output tsv 2>/dev/null)

    # Extract required model names
    required_models=$(jq -r ".parameters.$MODELS_PARAMETER.value[].name" ./infra/main.parameters.json 2>/dev/null)

    if [[ -z "$required_models" ]]; then
      echo "❌ ERROR: Failed to extract required model names from main.parameters.json"
      exit 1
    fi

    all_present=true
    for model in $required_models; do
      if ! grep -q -w "$model" <<< "$existing_deployments"; then
        all_present=false
        break
      fi
    done

    if [[ "$all_present" == "true" ]]; then
      echo "✅ All required model deployments already exist in AI service '$AISERVICE_NAME'."
      echo "⏭️ Skipping quota validation."
      exit 0
    else
      echo "🔍 AI service exists but some model deployments are missing — proceeding with quota validation."
    fi
  fi
fi

# If we reach here, continue with normal quota checks
aiModelDeployments=$(jq -c ".parameters.$MODELS_PARAMETER.value[]" ./infra/main.parameters.json)
if [[ $? -ne 0 ]]; then
  echo "❌ ERROR: Failed to parse main.parameters.json. Ensure jq is installed and the JSON is valid."
  exit 1
fi

az account set --subscription "$SUBSCRIPTION_ID"
echo "🎯 Active Subscription: $(az account show --query '[name, id]' --output tsv)"

quotaAvailable=true

while IFS= read -r deployment; do
  name=${AZURE_ENV_MODEL_NAME:-$(echo "$deployment" | jq -r '.name')}
  model=${AZURE_ENV_MODEL_NAME:-$(echo "$deployment" | jq -r '.model.name')}
  type=${AZURE_ENV_MODEL_DEPLOYMENT_TYPE:-$(echo "$deployment" | jq -r '.sku.name')}
  capacity=${AZURE_ENV_MODEL_CAPACITY:-$(echo "$deployment" | jq -r '.sku.capacity')}

  echo "🔍 Validating model deployment: $name ..."
  ./scripts/validate_model_quota.sh --location "$LOCATION" --model "$model" --capacity "$capacity" --deployment-type "$type"

  exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    if [[ $exit_code -eq 2 ]]; then
      # Quota validation handled inside script — stop immediately
      exit 1
    fi
    echo "❌ ERROR: Quota validation failed for model deployment: $name"
    quotaAvailable=false
  fi
done <<< "$(echo "$aiModelDeployments")"

if [[ "$quotaAvailable" = false ]]; then
  echo "❌ ERROR: One or more model deployments failed validation."
  exit 1
else
  echo "✅ All model deployments passed quota validation successfully."
  exit 0
fi