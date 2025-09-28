#!/bin/bash
# Copyright (c) 2022, NVIDIA CORPORATION.  All rights reserved.
#
# NVIDIA CORPORATION and its licensors retain all intellectual property
# and proprietary rights in and to this software, related documentation
# and any modifications thereto.  Any use, reproduction, disclosure or
# distribution of this software and related documentation without an express
# license agreement from NVIDIA CORPORATION is strictly prohibited.

# GPU family of target platform. Supported values: tegra, non-tegra
riva_target_gpu_family="non-tegra"

# Name of tegra platform that is being used. Supported tegra platforms: orin, xavier
riva_tegra_platform="orin"


####### Enable or Disable Riva Services #######

# For any language other than en-US: service_enabled_nlp must be set to false
service_enabled_asr=true
service_enabled_nlp=true
service_enabled_tts=true
service_enabled_nmt=false


####### Configure ASR service #######

# List of supported ASR models and languages for each ASR model
# Language code "multi" means a multilingual model, supported languages for various multilingual models are
# specified on https://docs.nvidia.com/deeplearning/riva/user-guide/docs/asr/asr-overview.html#multilingual-models
# "DO NOT EDIT" this field. Refer to this for valid values to be set in "asr_acoustic_model" and "asr_language_code" fields
declare -A asr_models_languages_map
asr_models_languages_map["conformer"]="ar-AR en-US en-GB de-DE es-ES es-US fr-FR hi-IN it-IT ja-JP ru-RU ko-KR pt-BR zh-CN nl-NL nl-BE"
asr_models_languages_map["conformer_xl"]="en-US"
asr_models_languages_map["conformer_unified"]="de-DE ja-JP zh-CN"
asr_models_languages_map["conformer_ml_cs"]="es-en-US"
asr_models_languages_map["conformer_unified_ml_cs"]="ja-en-JP"
asr_models_languages_map["parakeet_0.6b"]="en-US"
asr_models_languages_map["parakeet_0.6b_unified"]="en-US zh-CN"
asr_models_languages_map["parakeet_0.6b_unified_ml_cs"]="es-en-US"
asr_models_languages_map["parakeet_1.1b"]="en-US"
asr_models_languages_map["parakeet_1.1b_unified_ml_cs"]="em-ea"
asr_models_languages_map["parakeet_1.1b_unified_ml_cs_universal"]="multi"
asr_models_languages_map["parakeet_1.1b_unified_ml_cs_concat"]="multi"
asr_models_languages_map["parakeet-rnnt_1.1b"]="en-US"
asr_models_languages_map["parakeet-rnnt_1.1b_unified_ml_cs_universal"]="multi"
asr_models_languages_map["whisper_large"]="multi"
asr_models_languages_map["whisper_large_turbo"]="multi"
asr_models_languages_map["distil_whisper_large"]="en-US"
asr_models_languages_map["kotoba_whisper"]="ja-JP"
asr_models_languages_map["canary_1b"]="multi"
asr_models_languages_map["canary_0.6b_turbo"]="multi"

# Specify ASR acoustic model to deploy, as defined in "asr_models_languages_map" above
# Only one ASR acoustic model can be deployed at a time
asr_acoustic_model=("conformer")

# Specify ASR language to deploy, as defined in "asr_models_languages_map" above
# For multiple languages, enter space separated language codes
asr_language_code=("en-US")

# Specify ASR accessory model from below list, prebuilt model available only when "asr_acoustic_model" is set to "parakeet_1.1b"
# "diarizer" : deploy ASR model with Speaker Diarization model
# "silero" : deploy ASR model with Silero Voice Activity Detector (VAD) model
# "tele" : deploy ASR model trained with channel robust (telephony) data
# Only one ASR accessory model can be deployed at a time
asr_accessory_model=("")

# Set this field as true to deploy ASR with greedy decoder, instead of flashlight decoder
use_asr_greedy_decoder=false

# Set this as true to deploy streaming ASR in high throughput mode, instead of low latency mode
use_asr_streaming_throughput_mode=false

# Set this field as true to deploy an offline speaker diarization model
deploy_offline_diarizer=false


####### Configure TTS service #######

# List of supported TTS models and languages for each TTS model
# Language code "multi" means a multilingual model, supported languages for the multilingual models are
# specified on https://docs.nvidia.com/deeplearning/riva/user-guide/docs/tts/tts-overview.html#pretrained-tts-models
# "DO NOT EDIT" this field. Refer to this for valid values to be set in "tts_model" and "tts_language_code" fields
declare -A tts_models_languages_map
tts_models_languages_map["fastpitch_hifigan"]="en-US es-ES es-US it-IT de-DE zh-CN"
tts_models_languages_map["magpie"]="multi"
tts_models_languages_map["radtts_hifigan"]="en-US"
tts_models_languages_map["radttspp_hifigan"]="en-US"
tts_models_languages_map["pflow_hifigan"]="en-US"

# Specify TTS model to deploy, as defined in "tts_models_languages_map" above
# Only one TTS model can be deployed at a time
tts_model=("fastpitch_hifigan")

# Specify TTS language to deploy, as defined in "tts_models_languages_map" above
# For multiple languages, enter space separated language codes
tts_language_code=("en-US")


####### Configure translation services #######

# Text-to-Text translation (T2T):
# - service_enabled_nmt must be set to true
# Speech-to-Text translation (S2T):
# - service_enabled_asr, service_enabled_nmt must be set to true
# - Set language code of input speech in the asr_language_code field
# Speech-to-Speech translation (S2S):
# - service_enabled_asr, service_enabled_nmt, service_enabled_tts must be set to true
# - Set language code of input speech in the asr_language_code field
# - Set language code of output speech in the tts_language_code field
# Remote deployment for ASR and TTS for S2T and S2S use cases
# - NMT deployment supports using remote ASR and TTS service to allow better control on deployments.
# - You need to deploy a separate Riva ASR service and Riva TTS service to use this functionality.
# - Set nmt_remote_asr_service to point to your remote endpoint for Riva ASR service
# - Set nmt_remote_tts_service to point to your remote endpoint for Riva TTS service
# - By default, ASR and TTS service is used from the same local deployment along with NMT.
nmt_remote_asr_service=0.0.0.0:50051
nmt_remote_tts_service=0.0.0.0:50051

# Enable Riva Enterprise
# If enrolled in Enterprise, enable Riva Enterprise by setting configuration
# here. You must explicitly acknowledge you have read and agree to the EULA.
# RIVA_API_KEY=<ngc api key>
# RIVA_API_NGC_ORG=<ngc organization>
# RIVA_EULA=accept

# Specify one or more GPUs to use
# specifying more than one GPU is currently an experimental feature, and may result in undefined behaviours.
gpus_to_use="device=0"

# Specify the encryption key to use to deploy models
MODEL_DEPLOY_KEY="tlt_encode"

# Locations to use for storing models artifacts
#
# If an absolute path is specified, the data will be written to that location
# Otherwise, a Docker volume will be used (default).
#
# riva_init.sh will create a `rmir` and `models` directory in the volume or
# path specified.
#
# RMIR ($riva_model_loc/rmir)
# Riva uses an intermediate representation (RMIR) for models
# that are ready to deploy but not yet fully optimized for deployment. Pretrained
# versions can be obtained from NGC (by specifying NGC models below) and will be
# downloaded to $riva_model_loc/rmir by `riva_init.sh`
#
# Custom models produced by NeMo or TLT and prepared using riva-build
# may also be copied manually to this location $(riva_model_loc/rmir).
#
# Models ($riva_model_loc/models)
# During the riva_init process, the RMIR files in $riva_model_loc/rmir
# are inspected and optimized for deployment. The optimized versions are
# stored in $riva_model_loc/models. The riva server exclusively uses these
# optimized versions.
riva_model_loc="riva-model-repo"

if [[ $riva_target_gpu_family == "tegra" ]]; then
    riva_model_loc="`pwd`/model_repository"
fi

# The default RMIRs are downloaded from NGC by default in the above $riva_rmir_loc directory
# If you'd like to skip the download from NGC and use the existing RMIRs in the $riva_rmir_loc
# then set the below $use_existing_rmirs flag to true. You can also deploy your set of custom
# RMIRs by keeping them in the riva_rmir_loc dir and use this quickstart script with the
# below flag to deploy them all together.
use_existing_rmirs=false

# Ports to expose for Riva services
riva_speech_api_port="50051"
riva_speech_api_http_port="50000"

# NGC orgs
riva_ngc_org="nvidia"
riva_ngc_team="riva"
riva_ngc_image_version="2.19.0"
riva_ngc_model_version="2.19.0"


########## ASR MODELS ##########

models_asr=()

for lang_code in ${asr_language_code[@]}; do
    # filter unsupported models on tegra platform
    if [[ $riva_target_gpu_family == "tegra" ]]; then
      if [[ ${asr_acoustic_model} == "conformer_xl" || \
            ${asr_acoustic_model} == *"parakeet-rnnt"* || \
            ${asr_acoustic_model} == *"canary"* || \
            ${asr_acoustic_model} == *"whisper"* ]]; then
        echo "${asr_acoustic_model} model not available for ${riva_target_gpu_family} gpu family"
        exit 1
      fi
      if [[ ${asr_accessory_model} != "" || ${use_asr_greedy_decoder} == "true" || ${use_asr_streaming_throughput_mode} == "true" ]]; then
        echo "Prebuilt accessory model, greedy decoder and streaming-throughput mode with ASR are not available for ${riva_target_gpu_family} gpu family"
	exit 1
      fi
    fi

    # filter unsupported models and languages
    supported_languages_list=(${asr_models_languages_map[${asr_acoustic_model}]})
    if [[ ${#supported_languages_list[@]} == 0 ]]; then
      echo "Acoustic model ${asr_acoustic_model} not found. Provide model name as defined in asr_models_languages_map"
      exit 1
    else
      found=0
      for lang in "${supported_languages_list[@]}"; do
        if [[ ${lang} == ${lang_code} ]]; then
          found=1
          break
        fi
      done
      if [[ $found == 0 ]]; then
        echo "Acoustic model ${asr_acoustic_model} does not support ${lang_code} language. Provide language as defined in asr_models_languages_map"
        exit 1
      fi
    fi

    modified_asr_acoustic_model=${asr_acoustic_model//./-}
    modified_lang_code="_${lang_code//-/_}"
    modified_lang_code=${modified_lang_code,,}
    if [[ ${modified_lang_code} == "_multi" ]]; then
      modified_lang_code=""
    fi

    # check if prebuilt RMIR with accessory model is to be used
    accessory_model=""
    if [[ ${asr_accessory_model} != "" ]]; then
      if [[ ${asr_accessory_model} != "diarizer" && ${asr_accessory_model} != "silero" && ${asr_accessory_model} != "tele" ]]; then
        echo "Invalid accessory model ${asr_accessory_model}. Only diarizer, silero and tele are supported"
        exit 1
      fi
      if [[ ${asr_acoustic_model} != "parakeet_1.1b" ]]; then
        echo "Only parakeet_1.1b + ${asr_accessory_model} is available as prebuilt model. Perform riva-build to create RMIR for other ASR models with ${asr_accessory_model}"
        exit 1
      fi
      if [[ ${use_asr_greedy_decoder} == "true" ]]; then
        echo "Greedy decoder is not supported with accessory models. Set use_asr_greedy_decoder to false"
        exit 1
      fi
      if [[ ${use_asr_streaming_throughput_mode} == "true" && ${asr_accessory_model} == "diarizer" ]]; then
        echo "Streaming throughput mode is not supported with accessory model ${asr_accessory_model}, Set use_asr_streaming_throughput_mode to false"
        exit 1
      fi
      accessory_model="_${asr_accessory_model}"
    fi

    # check if greedy decoder should be used
    decoder=""
    if [[ ${use_asr_greedy_decoder} == "true" || \
          ${asr_acoustic_model} == "parakeet_1.1b_unified_ml_cs_universal" || \
          ${asr_acoustic_model} == "parakeet_1.1b_unified_ml_cs_concat" || \
          ${asr_acoustic_model} == "parakeet-rnnt_1.1b" || \
          ${asr_acoustic_model} == "parakeet-rnnt_1.1b_unified_ml_cs_universal" ]]; then
      decoder="_gre"
    fi

    # check if streaming throughput mode is to be used
    streaming_mode=""
    if [[ ${use_asr_streaming_throughput_mode} == "true" ]]; then
      streaming_mode="_thr"
    fi

    # populate ngc paths
    if [[ $riva_target_gpu_family == "tegra" ]]; then
        models_asr+=(
          ### Streaming w/ CPU decoder, best latency configuration
            "${riva_ngc_org}/${riva_ngc_team}/models_asr_${modified_asr_acoustic_model}${modified_lang_code}_str:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
        )
        if [[ ${deploy_offline_diarizer} == "true" ]]; then
          models_asr+=(
            ### Offline w/ CPU decoder
              "${riva_ngc_org}/${riva_ngc_team}/rmir_asr_${modified_asr_acoustic_model}${modified_lang_code}_ofl${decoder}:${riva_ngc_model_version}"
              "${riva_ngc_org}/${riva_ngc_team}/rmir_diarizer_offline:${riva_ngc_model_version}"
          )
        fi
    else
      if [[ ${asr_acoustic_model} != *"whisper"* && ${asr_acoustic_model} != "parakeet-rnnt_1.1b" && ${asr_acoustic_model} != *"canary"* ]]; then
        models_asr+=(
          ### Streaming w/ CPU decoder, best latency or best throughput configuration
            "${riva_ngc_org}/${riva_ngc_team}/rmir_asr_${modified_asr_acoustic_model}${modified_lang_code}_str${streaming_mode}${decoder}${accessory_model}:${riva_ngc_model_version}"
        )
      fi

      ### Offline w/ CPU decoder
      if [[ ${asr_acoustic_model} == *"whisper"* || ${asr_acoustic_model} == *"canary"* ]]; then
        models_asr+=(
          "${riva_ngc_org}/${riva_ngc_team}/rmir_asr_${modified_asr_acoustic_model}_ofl:${riva_ngc_model_version}"
        )
      else
        if [[ ${asr_accessory_model} == "diarizer" ]]; then
          models_asr+=(
            "${riva_ngc_org}/${riva_ngc_team}/rmir_asr_${modified_asr_acoustic_model}${modified_lang_code}_ofl${decoder}:${riva_ngc_model_version}"
          )
        else
          models_asr+=(
            "${riva_ngc_org}/${riva_ngc_team}/rmir_asr_${modified_asr_acoustic_model}${modified_lang_code}_ofl${decoder}${accessory_model}:${riva_ngc_model_version}"
          )
	fi
	if [[ ${deploy_offline_diarizer} == "true" ]]; then
          models_asr+=(
	    "${riva_ngc_org}/${riva_ngc_team}/rmir_diarizer_offline:${riva_ngc_model_version}"
          )
	fi
      fi
    fi

    ### Punctuation model
    if [[ ${asr_acoustic_model} != *"unified"* && ${asr_acoustic_model} != *"whisper"* && ${asr_acoustic_model} != *"canary"* ]]; then
      pnc_lang=$(echo $modified_lang_code | cut -d "_" -f 2)
      pnc_region=${modified_lang_code##*_}
      modified_lang_code="_${pnc_lang}_${pnc_region}"
      if [[ $riva_target_gpu_family == "tegra" ]]; then
        if [[ "$lang_code" == "en-US" ]]; then
          models_asr+=(
          #  "${riva_ngc_org}/${riva_ngc_team}/models_nlp_punctuation_bert_large${modified_lang_code}:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
          )
	fi
        models_asr+=(
          "${riva_ngc_org}/${riva_ngc_team}/models_nlp_punctuation_bert_base${modified_lang_code}:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
        )
      else
        if [[ "$lang_code" == "en-US" ]]; then
          models_asr+=(
          #  "${riva_ngc_org}/${riva_ngc_team}/rmir_nlp_punctuation_bert_large${modified_lang_code}:${riva_ngc_model_version}"
          )
	fi
        models_asr+=(
          "${riva_ngc_org}/${riva_ngc_team}/rmir_nlp_punctuation_bert_base${modified_lang_code}:${riva_ngc_model_version}"
        )
      fi
    fi
done

########## NLP MODELS ##########

if [[ $riva_target_gpu_family == "tegra" ]]; then
  models_nlp=(
  ### Bert base Punctuation model
      "${riva_ngc_org}/${riva_ngc_team}/models_nlp_punctuation_bert_base_en_us:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
  #    "${riva_ngc_org}/${riva_ngc_team}/models_nlp_punctuation_bert_large_en_us:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
  )
else
  models_nlp=(
  ### Bert base Punctuation model
      "${riva_ngc_org}/${riva_ngc_team}/rmir_nlp_punctuation_bert_base_en_us:${riva_ngc_model_version}"
  #    "${riva_ngc_org}/${riva_ngc_team}/rmir_nlp_punctuation_bert_large_en_us:${riva_ngc_model_version}"
  )
fi

########## TTS MODELS ##########

models_tts=()

for lang_code in ${tts_language_code[@]}; do
  # filter unsupported models on tegra platform
  if [[ $riva_target_gpu_family == "tegra" ]]; then
    if [[ ${tts_model} == "magpie" ]]; then
      echo "${tts_model} model not available for ${riva_target_gpu_family} gpu family"
      exit 1
    fi
  fi

  # filter unsupported models and languages
  supported_languages_list=(${tts_models_languages_map[${tts_model}]})
  if [[ ${#supported_languages_list[@]} == 0 ]]; then
      echo "Model ${tts_model} not found. Provide model name as defined in tts_models_languages_map"
      exit 1
  else
    found=0
    for lang in "${supported_languages_list[@]}"; do
      if [[ ${lang} == ${lang_code} ]]; then
        found=1
        break
      fi
    done
    if [[ $found == 0 ]]; then
      echo "Model ${tts_model} does not support ${lang_code} language. Provide language as defined in tts_models_languages_map"
      exit 1
    fi
  fi

  modified_lang_code="_${lang_code//-/_}"
  modified_lang_code=${modified_lang_code,,}
  if [[ ${modified_lang_code} == "_multi" ]]; then
    modified_lang_code="_multilingual"
  fi

  # populate ngc paths
  if [[ $riva_target_gpu_family == "tegra" ]]; then
    if [[ ${lang_code} == "multi" || ${lang_code} == "en-US" || ${lang_code} == "zh-CN" || ${lang_code} == "es-US" ]]; then
      if [[ ${tts_model} == "pflow_hifigan" ]]; then
        ### This is a zero shot model for synthesizing speech using audio prompt input, require access to ea-riva-tts NGC org for using it
        models_tts+=(
	  "gjaugwraudqz/rmir_tts_${tts_model}${modified_lang_code}_ipa:${riva_ngc_model_version}"
        )
      else
        models_tts+=(
          "${riva_ngc_org}/${riva_ngc_team}/models_tts_${tts_model}${modified_lang_code}_ipa:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
        )
      fi
    else
      if [[ ${lang_code} != "de-DE" ]]; then
        models_tts+=(
            "${riva_ngc_org}/${riva_ngc_team}/models_tts_${tts_model}${modified_lang_code}_f_ipa:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
        )
      fi
      models_tts+=(
          "${riva_ngc_org}/${riva_ngc_team}/models_tts_${tts_model}${modified_lang_code}_m_ipa:${riva_ngc_model_version}-${riva_target_gpu_family}-${riva_tegra_platform}"
      )
    fi
  else
    if [[ ${lang_code} == "multi" || ${lang_code} == "en-US" || ${lang_code} == "zh-CN" || ${lang_code} == "es-US" ]]; then
      if [[ ${tts_model} == "pflow_hifigan" ]]; then
        ### This is a zero shot model for synthesizing speech using audio prompt input, require access to ea-riva-tts NGC org for using it
        models_tts+=(
          "gjaugwraudqz/rmir_tts_${tts_model}${modified_lang_code}_ipa:${riva_ngc_model_version}"
        )
      else
        models_tts+=(
          "${riva_ngc_org}/${riva_ngc_team}/rmir_tts_${tts_model}${modified_lang_code}_ipa:${riva_ngc_model_version}"
        )
      fi
    else
      if [[ ${lang_code} != "de-DE" ]]; then
        models_tts+=(
            "${riva_ngc_org}/${riva_ngc_team}/rmir_tts_${tts_model}${modified_lang_code}_f_ipa:${riva_ngc_model_version}"
        )
      fi
      models_tts+=(
          "${riva_ngc_org}/${riva_ngc_team}/rmir_tts_${tts_model}${modified_lang_code}_m_ipa:${riva_ngc_model_version}"
      )
    fi
  fi
done

######### NMT models ###############

# Models follow Source language _ One or more target languages model architecture
# Source or target language "any" means the model supports 32 languages mentioned in docs.
# e.g., rmir_megatronnmt_en_any_500m is a English to 32 languages megatron model

models_nmt=(
  ###### Megatron models
  #"${riva_ngc_org}/${riva_ngc_team}/rmir_megatronnmt_any_en_500m:${riva_ngc_model_version}"
  #"${riva_ngc_org}/${riva_ngc_team}/rmir_megatronnmt_en_any_500m:${riva_ngc_model_version}"
  #"${riva_ngc_org}/${riva_ngc_team}/rmir_nmt_megatron_1b_any_en:${riva_ngc_model_version}"
  #"${riva_ngc_org}/${riva_ngc_team}/rmir_nmt_megatron_1b_en_any:${riva_ngc_model_version}"
  "${riva_ngc_org}/${riva_ngc_team}/rmir_nmt_megatron_1b_any_any:${riva_ngc_model_version}"
)

NGC_TARGET=${riva_ngc_org}
if [[ ! -z ${riva_ngc_team} ]]; then
  NGC_TARGET="${NGC_TARGET}/${riva_ngc_team}"
else
  team="\"\""
fi

# Specify paths to SSL Key and Certificate files to use TLS/SSL Credentials for a secured connection.
# If either are empty, an insecure connection will be used.
# Stored within container at /ssl/servert.crt and /ssl/server.key
# Optional, one can also specify a root certificate, stored within container at /ssl/root_server.crt
# Set ssl_use_mutual_auth to true for enabling mutual TLS (mTLS) authentication
ssl_server_cert=""
ssl_server_key=""
ssl_root_cert=""
ssl_use_mutual_auth=false

# define Docker images required to run Riva
image_speech_api="nvcr.io/${NGC_TARGET}/riva-speech:${riva_ngc_image_version}"

# daemon names
riva_daemon_speech="riva-speech"
if [[ $riva_target_gpu_family != "tegra" ]]; then
    riva_daemon_client="riva-client"
fi
