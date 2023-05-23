#!/bin/bash

set -euxo pipefail

readonly SPARK_JARS_DIR=/usr/lib/spark/jars

readonly DEFAULT_INIT_ACTIONS_REPO=gs://dataproc-initialization-actions
readonly INIT_ACTIONS_REPO="$(/usr/share/google/get_metadata_value attributes/init-actions-repo ||
  echo ${DEFAULT_INIT_ACTIONS_REPO})"
readonly INIT_ACTIONS_DIR=$(mktemp -d -t dataproc-init-actions-XXXX)


R_VERSION="$(R --version | sed -n 's/.*version[[:blank:]]\+\([0-9]\+\.[0-9]\).*/\1/p')"
readonly R_VERSION

CONDA_PACKAGES=(
  "r-dplyr=1.0"
  "r-essentials=${R_VERSION}"
  "r-sparklyr=1.7"
  "scikit-learn=0.24"
  "pytorch=1.9"
  "torchvision=0.9"
  "xgboost=1.4"
)

# rapids-xgboost (part of the RAPIDS library) requires a custom build of
# xgboost that is incompatible with r-xgboost. As such, r-xgboost is not
# installed into the MLVM if RAPIDS support is desired.
#if [[ -z ${RAPIDS_RUNTIME} ]]; then
#  CONDA_PACKAGES+=("r-xgboost=1.4")
#fi

PIP_PACKAGES=(
  "mxnet==1.8.*"
  "rpy2==3.4.*"
  "sparksql-magic==0.0.*"
  "tensorflow-datasets==4.4.*"
  "tensorflow-hub==0.12.*"
)

PIP_PACKAGES+=(
  "spark-tensorflow-distributor==1.0.0"
  "tensorflow==2.6.*"
  "tensorflow-estimator==2.6.*"
  "tensorflow-io==0.20"
  "tensorflow-probability==0.13.*"
)

readonly CONDA_PACKAGES
readonly PIP_PACKAGES

mkdir -p ${SPARK_JARS_DIR}

function execute_with_retries() {
  local -r cmd=$1
  for ((i = 0; i < 10; i++)); do
    if eval "$cmd"; then
      return 0
    fi
    sleep 5
  done
  echo "Cmd '${cmd}' failed."
  return 1
}

function download_spark_jar() {
  local -r url=$1
  local -r jar_name=${url##*/}
  curl -fsSL --retry-connrefused --retry 10 --retry-max-time 30 \
    "${url}" -o "${SPARK_JARS_DIR}/${jar_name}"
}

function download_init_actions() {
  # Download initialization actions locally.
  mkdir "${INIT_ACTIONS_DIR}"/{initactions}

  gsutil -m rsync -r "${INIT_ACTIONS_REPO}/initactions/" "${INIT_ACTIONS_DIR}/initactions/"

  find "${INIT_ACTIONS_DIR}" -name '*.sh' -exec chmod +x {} \;
}

function install_conda_packages() {
  local base
  base=$(conda info --base)
  local -r mamba_env_name=mamba
  local -r mamba_env=${base}/envs/mamba
  local -r extra_packages="$(/usr/share/google/get_metadata_value attributes/CONDA_PACKAGES || echo "")"
  local -r extra_channels="$(/usr/share/google/get_metadata_value attributes/CONDA_CHANNELS || echo "")"

  conda config --add channels pytorch
  conda config --add channels conda-forge

  # Create a separate environment with mamba.
  # Mamba provides significant decreases in installation times.
  conda create -y -n ${mamba_env_name} mamba

  execute_with_retries "${mamba_env}/bin/mamba install -y ${CONDA_PACKAGES[*]} -p ${base}"

  if [[ -n "${extra_channels}" ]]; then
    for channel in ${extra_channels}; do
      "${mamba_env}/bin/conda" config --add channels "${channel}"
    done
  fi

  if [[ -n "${extra_packages}" ]]; then
    execute_with_retries "${mamba_env}/bin/mamba install -y ${extra_packages[*]} -p ${base}"
  fi

  # Clean up environment
  "${mamba_env}/bin/mamba" clean -y --all

  # Remove mamba env when done
  conda env remove -n ${mamba_env_name}
}

function install_pip_packages() {
  local -r extra_packages="$(/usr/share/google/get_metadata_value attributes/PIP_PACKAGES || echo "")"

  execute_with_retries "pip install ${PIP_PACKAGES[*]}"

  if [[ -n "${extra_packages}" ]]; then
    execute_with_retries "pip install ${extra_packages[*]}"
  fi
}


function main() {
  # Download initialization actions
  echo "Downloading initialization actions"
  download_init_actions

  # Install Conda packages
  echo "Installing Conda packages"
  install_conda_packages

  # Install Pip packages
  echo "Installing Pip Packages"
  install_pip_packages
}

main