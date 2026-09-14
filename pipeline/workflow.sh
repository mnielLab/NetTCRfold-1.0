#!/bin/bash
#SBATCH --job-name=runAF3_fullworkflow
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --cpus-per-task=5
#SBATCH --mem=64G
#SBATCH --time=250:00:00
#SBATCH --output=logs/slurm_%A_%a.out
#SBATCH --error=logs/slurm_%A_%a.err

#Strict execution mode
set -Eeuo pipefail

#Machine/install-specific paths — see configs/envExample.cfg
source configs/env.cfg
source "$CONDA_SH"
conda activate NetTCRfold

#Path to the run's config.cfg, passed as the first argument (e.g.
#`sbatch workflow.sh configs/configMinimal.cfg`). Defaults to configs/config.cfg.
CONFIG_FILE="${1:-configs/config.cfg}"
source "$CONFIG_FILE"

#Resolve DATA_DIR to an absolute path. The log-path derivation below strips
#two directory levels off of it; a relative DATA_DIR with too few segments
#(e.g. "examples/data_minimal/") runs out of levels to strip and silently
#collapses both log directories into one instead of erroring.
DATA_DIR="$(cd "$DATA_DIR" && pwd)/"

src=$PROJECT_ROOT
mhcdb=$src/pipeline/databases/mhc_sequences
dockq_repo=$DOCKQ_REPO

#Slurm array concurrency (override in config if needed)
CONCURRENT="${CONCURRENT:-1}"
CONCURRENT_INFERENCE="${CONCURRENT_INFERENCE:-1}"

#AF3 inference sizing (override in config if needed)
NUM_SEEDS="${NUM_SEEDS:-1}"
NUM_DIFFUSION="${NUM_DIFFUSION:-5}"

#Metrics collection array-job sizing (override in config if needed)
NUM_METRIC_SPLITS="${NUM_METRIC_SPLITS:-1}"
CONCURRENT_METRICS="${CONCURRENT_METRICS:-1}"

#Which array index to start submitting from (override in config if needed)
GLOBAL_START="${GLOBAL_START:-1}"

#Detects the largest ArrayTaskID in a tab-separated *_to_array.txt file
max_array_task_id() {
    local file="$1"
    if [[ ! -s "$file" ]]; then
        echo "ERROR: array map file not found or empty: $file (run the data preprocessing step first)" >&2
        exit 1
    fi
    local max
    max=$(awk -F'\t' 'NR>1 && $1+0>max {max=$1+0} END {print max+0}' "$file")
    if [[ "$max" -le 0 ]]; then
        echo "ERROR: could not determine the largest ArrayTaskID in $file" >&2
        exit 1
    fi
    echo "$max"
}

#Define paths
suffix_output_inference="${SUFFIX_OUTPUT:-}"
suffix_output_datagen="${SUFFIX_DATAGEN:-}"

ARRAY_MAP_DATA="${DATA_DIR}/chainid_to_array.txt"
ARRAY_MAP_INFERENCE="${DATA_DIR}/samplename_to_array.txt"
output_savedata="${DATA_DIR}/af3_output"
input_basejson="${DATA_DIR}/jsonFiles"
output_customjson="${input_basejson}/customJSON${suffix_output_datagen}/"
output_datageneration="${output_savedata}/dataPipelineOut${suffix_output_datagen}/"
output_inference="${output_savedata}/structInference${suffix_output_inference}/"

logs_path="${DATA_DIR%/}"

logs_path_inside="${logs_path%/*}/logs/"

echo "Logs will be saved in: ${logs_path_inside}"
mkdir -p "${logs_path_inside}"

#logs_path="${logs_path%/*}"
#logs_path="${logs_path%/*}/logs/"

#echo "Logs path are: ${logs_path}"

#mkdir -p "${logs_path}/"

logs_path_datageneration="${logs_path_inside}/af3_datageneration_workflow${suffix_output_datagen}/"
logs_path_inference="${logs_path_inside}/af3_inference${suffix_output_inference}/"

logs_path_datageneration_slurm="${logs_path_inside}/af3_datageneration_workflow${suffix_output_datagen}/"
logs_path_inference_slurm="${logs_path_inside}/af3_inference${suffix_output_inference}/"

##Redirect log
name_log="${DATA_DIR%/*}"
name_log="${name_log%/*}"
name_log="${name_log##*/}"
exec >"${logs_path_inside}/${name_log}${suffix_output_inference}_${SLURM_JOB_ID}.out" 2>"${logs_path_inside}/${name_log}${suffix_output_inference}_${SLURM_JOB_ID}.err"


##1.Perform data preprocessing
if $RUN_JSON_WITH_MSA_TEMPLATE_GENERATION; then
    echo "Performing data preprocessing step: Generating JSON for data generation step with MSA and Template"
    echo "Processing file $DATA_DIR/$INPUT_FILE"

    python -m NetTCRfold.jsonPrep.dataPreprocessing \
        -i "$DATA_DIR/$INPUT_FILE" \
        -o "$DATA_DIR" \
        -m "$mhcdb"

    echo "Data preprocessing finished"

else
    echo "Skipping data preprocessing step"
fi

if $RUN_DATA_GENERATION_PIPELINE; then
    TOTAL_TASKS_DATA=$(max_array_task_id "$ARRAY_MAP_DATA")
    echo "Detected TOTAL_TASKS_DATA=$TOTAL_TASKS_DATA from $ARRAY_MAP_DATA"

    read -r -a combinations <<< "${TEMPLATE_SELECTION_METHOD:-onquery}"

    for m in "${combinations[@]}"; do
        if [[ "$m" != "onquery" && "$m" != "standard" ]]; then
            echo "ERROR: invalid TEMPLATE_SELECTION_METHOD value '$m' — only 'onquery' and 'standard' are supported" >&2
            exit 1
        fi
    done

    for template_selection_method in "${combinations[@]}"; do
        output_folder="${output_datageneration}/template_${template_selection_method}"
        echo "Running AF data generation step with template selection method ${template_selection_method}. Results will be saved in $output_folder"

        mkdir -p "$logs_path_datageneration"
        mkdir -p "$logs_path_datageneration_slurm"
        max_array=1000

        for start in $(seq $GLOBAL_START $max_array $TOTAL_TASKS_DATA); do
            end=$((${start} + ${max_array} - 1))
            [ $end -gt $TOTAL_TASKS_DATA ] && end=$TOTAL_TASKS_DATA

            array_length=$((${end} - ${start} + 1))
            echo "Submitting array: $start-$end%$CONCURRENT (length $array_length) for template selection method: $template_selection_method"

            jobid=$(sbatch --parsable --wait \
            --array=1-${array_length}%${CONCURRENT} \
            --output="${logs_path_datageneration_slurm}/slurm_%A_%a.out" \
            --error="${logs_path_datageneration_slurm}/slurm_%A_%a.err" \
            src/NetTCRfold/runAF3_dataGeneration.sh \
            $ARRAY_MAP_DATA $input_basejson/"json_msa_template" $output_folder "$logs_path_datageneration" \
            $template_selection_method $start)

            echo "Job $jobid finished."
        done
    done
else
    echo "Skipping AF3 data generation step"
fi

if $RUN_CUSTOM_JSON_GENERATION; then
    echo "Generating custom JSON input files with different MSA and Template settings"
    python -m NetTCRfold.jsonPrep.create_custom_json \
        -i "$output_datageneration" \
        -o "$output_customjson" \
        -d "$DATA_DIR/${INPUT_FILE%.csv}_hla_withid.csv" \
        -c "${MSA_TEMPLATE_COMBINATIONS:-unpaired_onquery}"
        
    echo "Custom JSON input generation finished. Files saved in $output_customjson"
else
    echo "Skipping custom JSON input generation"
fi

#2. Perform af3 inference step in selected folders
if $RUN_AF3_INFERENCE; then
    echo "Running AF3 inference step"

    TOTAL_TASKS_INFERENCE=$(max_array_task_id "$ARRAY_MAP_INFERENCE")
    echo "Detected TOTAL_TASKS_INFERENCE=$TOTAL_TASKS_INFERENCE from $ARRAY_MAP_INFERENCE"

    if [[ -z "${FOLDERS_INFERENCE:-}" ]]; then
        echo "FOLDERS not provided in config — processing all subfolders in $output_customjson"
        folders=$(find "$output_customjson" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
        echo "Processing folders: $folders"
    else
        folders=$FOLDERS_INFERENCE
        echo "Using folders from config: $folders"
    fi

    mkdir -p "$logs_path_inference"
    mkdir -p "$logs_path_inference_slurm"
    for folder in $folders; do
        folder_path="$output_customjson/$folder"
        max_array=1000
        for start in $(seq $GLOBAL_START $max_array $TOTAL_TASKS_INFERENCE); do
            end=$((${start} + ${max_array} - 1))
            [ $end -gt $TOTAL_TASKS_INFERENCE ] && end=$TOTAL_TASKS_INFERENCE

            array_length=$((${end} - ${start} + 1))
            echo "Submitting array: $start-$end%$CONCURRENT_INFERENCE (length $array_length) for folder: $folder"

            jobid=$(sbatch --parsable --wait \
            --array=1-${array_length}%${CONCURRENT_INFERENCE} \
            --output="${logs_path_inference_slurm}/slurm_%A_%a.out" \
            --error="${logs_path_inference_slurm}/slurm_%A_%a.err" \
            src/NetTCRfold/runAF3_inference.sh \
            "$folder_path" "$output_inference" "$logs_path_inference" \
            "$ARRAY_MAP_INFERENCE" "$NUM_SEEDS" "$NUM_DIFFUSION" "$start")

            echo "Job $jobid for $folder finished."
        done
    done

    echo "All folders processed sequentially."
else 
    echo "Skipping AF3 inference step"
fi

if $COMPUTE_DOCKQ; then
    echo "Computing DockQ scores"
    if [[ -z "${FOLDERS_METRIC_COLLECTION:-}" ]]; then
        echo "FOLDERS not provided in config — processing all subfolders in $output_inference"
        folders_dockq=$(find "$output_inference" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
        echo "Folders to process: $folders_dockq"
    else
        folders_dockq=$FOLDERS_METRIC_COLLECTION
        echo "Using folders from config. Folders to process: $folders_dockq"
    fi

    for folder in $folders_dockq; do
        folder_path="$output_inference/$folder"
        echo "Computing Dockq for files in $folder"
        python -m NetTCRfold.metrics.computeDockq \
            -i "$folder_path" \
            -t "$TEMPLATE_PATH" \
            -d "$dockq_repo" \
            -n1 D E \
            -m1 D E \
            -n2 C A \
            -m2 C A \
            -s "_dockQonpMHC"
        echo "Computation for $folder finished."
        find "$folder_path" -mindepth 3 -maxdepth 3 -type f -name "*.pdb" -delete
    done
    echo "DockQ collected for all folders"
else
    echo "Skipping DockQ computation"
fi

if $RUN_METRICS_COLLECTION; then

    echo "Collecting metrics step"
    if [[ -z "${FOLDERS_METRIC_COLLECTION:-}" ]]; then
        echo "FOLDERS not provided in config — processing all subfolders in $output_inference"
        folders_metric_collection=$(find "$output_inference" -mindepth 1 -maxdepth 1 -type d -printf '%f\n')
        echo "Folders to process: $folders_metric_collection"
    else
        folders_metric_collection=$FOLDERS_METRIC_COLLECTION
        echo "Using folders from config. Folders to process: $folders_metric_collection"
    fi

    echo "Collecting all metrics for AF3 generated structures and combining them in one file"

    if $COMPUTE_DOCKQ; then
        suffixes=("_dockQonpMHC")
    else
        suffixes=("")
        echo "DockQ will not be collected, only AF3 metrics will be collected and combined"
    fi

    for folder in $folders_metric_collection; do
        folder_path="$output_inference/$folder"
        echo "Collecting metrics for files in $folder"
        for i in "${!suffixes[@]}"; do
            suffix="${suffixes[$i]}"
            metrics_logs="${logs_path_inside}/af3_metrics${suffix_output_inference}/${folder}${suffix}"
            mkdir -p "$metrics_logs"
            metrics_logs_slurm="${logs_path}/af3_metrics${suffix_output_inference}/${folder}${suffix}"
            mkdir -p "$metrics_logs_slurm"

            echo "Submitting metrics collection array job for $folder (suffix=$suffix): $NUM_METRIC_SPLITS splits, %${CONCURRENT_METRICS} concurrent"
            jobid=$(sbatch --parsable --wait \
                --array=0-$((NUM_METRIC_SPLITS - 1))%${CONCURRENT_METRICS} \
                --output="${metrics_logs_slurm}/slurm_%A_%a.out" \
                --error="${metrics_logs_slurm}/slurm_%A_%a.err" \
                src/NetTCRfold/collect_metrics_slurm_parallel.sh \
                "$folder_path" "$suffix" "$NUM_METRIC_SPLITS" "$metrics_logs")
            echo "Job $jobid for metrics collection ($folder, suffix=$suffix) finished."

            echo "Merging split metrics for $folder (suffix=$suffix)"
            python -m NetTCRfold.metrics.mergeMetrics \
                -i "$folder_path" \
                -n "$NUM_METRIC_SPLITS" \
                -s "$suffix"
        done
        echo "Computation for $folder finished."
    done

    for i in "${!suffixes[@]}"; do
        suffix="${suffixes[$i]}"
        python -m NetTCRfold.metrics.combine_metrics_onefile \
            -i "$output_inference" \
            -s "$suffix"

        echo "Expanding chain-pair metrics for suffix=$suffix"
        python -m NetTCRfold.metrics.expandMetrics \
            -i "${output_inference}/allresults_merged${suffix}.csv" \
            -o "${output_inference}/allresults_merged_expanded${suffix}.csv"
    done

else
    echo "Skipping metrics collection"

fi

echo "Pipeline completed"

