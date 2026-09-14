# NetTCRfold

NetTCRfold is a pipeline for predicting the 3D structure of T-cell receptor–peptide-MHC (TCR-pMHC) complexes. It consists of a TCR-pMHC-specialized version of AlphaFold3 (the `alphafold3_tcrpmhc` folder in this repository) with the surrounding steps needed to actually use it (the pipeline folder).

In short: 
It turns a plain CSV of TCR/peptide/MHC sequences into AF3-ready inputs (MSA + template search), it runs structure inference over many datapoints as SLURM array jobs and it scores resulting models with confidence metrics, interface metrics, and (if solved structures are available) DockQ against ground truth.

The whole pipeline is driven by a single entry point, `pipeline/workflow.sh`, controlled by two small config files (`env.cfg` for machine-specific paths, `config.cfg` for what to run and how).

## Installation (quick)

1. Clone the repository:
   ```
   git clone git@github.com:pballesteroscuartero/NetTCRfold.git
   cd NetTCRfold
   ```

2. Request access to the AF3 weights and place them inside `alphafold3_tcrpmhc/` (manual step — see [Advanced: detailed installation](#advanced-detailed-installation--troubleshooting)).

3. Run the installer, which downloads the AF3 image, chemical components, curated databases, DockQ, and creates the conda environment:

   ```
   bash install.sh
   ```

For the full step-by-step breakdown (in case `install.sh` doesn't fit your setup) and common setup errors, see [Advanced: detailed installation](#advanced-detailed-installation--troubleshooting).

## Quickstart: run the minimal example - one datapoint

The repo includes a ready-to-use single-datapoint example (`pipeline/examples/data_minimal/single_target.csv`) and a matching minimal config (`pipeline/configs/configMinimal.cfg`), so you can confirm your install works end to end before pointing the pipeline at your own data.

1. Fill in your machine-specific paths once:
   ```
   cp pipeline/configs/envExample.cfg pipeline/configs/env.cfg
   ```
   then edit `pipeline/configs/env.cfg` (conda location and repository root — see [env.cfg reference](#envcfg)).

2. Submit the pipeline with the minimal config, from inside `pipeline/` (paths in the config are relative to it):
   ```
   cd pipeline
   sbatch workflow.sh configs/configMinimal.cfg
   ```
   `workflow.sh` needs SLURM (it submits its own sub-jobs with `sbatch`), so this has to run on a system with SLURM available, and it must be submitted with `sbatch`, not run directly with `bash`. 

This runs JSON generation, MSA/template generation with the default parameters as defined in our paper (unpaired MSA only and template selection on query), structure inference, and metrics collection (DockQ is off by default in the minimal config — see [configMinimal.cfg](pipeline/configs/configMinimal.cfg)). The final combined, expanded metrics table lands at:
```
pipeline/examples/data_minimal/af3_output/structInference/allresults_merged_expanded.csv
```

There is also an example with 10 datapoints under: `pipeline/examples/data_10examples/benchmark_10examples.csv`) 

## Pipeline overview

`workflow.sh` runs up to six steps in order, each one turned on/off in `config.cfg`:

1. **RUN_JSON_WITH_MSA_TEMPLATE_GENERATION** — decompose the input CSV into unique chains and write AF3-format JSON per chain (so shared chains aren't reprocessed).
2. **RUN_DATA_GENERATION_PIPELINE** — MSA generation and template selection per chain (as SLURM array jobs).
3. **RUN_CUSTOM_JSON_GENERATION** — recombine chains into complexes with the MSA/template configuration you want to model.
4. **RUN_AF3_INFERENCE** — run AF3 structure inference on the reconstructed complexes.
5. **COMPUTE_DOCKQ** — (optional) score each model against a solved structure with DockQ, if you have one.
6. **RUN_METRICS_COLLECTION** — collect confidence/interface metrics (and DockQ, if available) into one table per folder, then combine and expand them into a single flat CSV across all folders.

Because each step reads what the previous one wrote from disk, you can run them independently across separate submissions — e.g. run inference now, come back and run `COMPUTE_DOCKQ` later once you have solved structures, then run `RUN_METRICS_COLLECTION`. Metrics collection automatically picks up DockQ scores whenever they exist on disk, regardless of which run computed them.

General usage: pick which steps to run and set the relevant fields in a config file (start from `configs/configMinimal.cfg` or `configs/config.cfg`), then `sbatch workflow.sh <path-to-your-config>` from inside `pipeline/`.

## Preparing your own input data

To run the pipeline on your own targets, provide a CSV with the columns:

- `Epitope_aa` or `peptide`: the peptide to model.
- `TRA_aa`: TCR alpha chain sequence (we use the variable-domain-trimmed version).
- `TRB_aa`: TCR beta chain sequence (variable-domain-trimmed).
- `MHCA_aa` (optional): MHC alpha chain variable domain sequence. If absent, inferred from `allele` below.
- `allele` or `HLA` (optional): MHC allele, used to look up `MHCA_aa` in the MHC database if not provided directly. Should be in the format: HLA-A*01:01.
- `pdb_id` (optional): PDB ID of the datapoint.
- `A1, A2, A3, B1, B2, B3` (optional): CDR1-3 sequences of chains A/B — used only for naming.
- `name` (optional): unique identifier per datapoint. Falls back to `pdb_id`, then to `peptide_A1_A2_A3_B1_B2_B3` or `peptide_TRAaa_TRBaa` if not provided.

---

# Advanced

## Advanced: detailed installation & troubleshooting

1. Clone the repository:
   ```
   git clone git@github.com:pballesteroscuartero/NetTCRfold.git
   cd NetTCRfold
   ```

2. Request access to AF3 weights and place them inside the `alphafold3_tcrpmhc` folder.

3. Download the image for running the modified AF3 pipeline:
   ```
   wget -r -np -nH --cut-dirs=4 -R "index.html*" -P apptainer/ \
       https://services.healthtech.dtu.dk/suppl/immunology/NetTCRaFold-1.0/image/
   ```

4. Download the chemical components:
   ```
   wget -P alphafold3_tcrpmhc/src/alphafold3/constants/converters \
     https://services.healthtech.dtu.dk/suppl/immunology/NetTCRaFold-1.0/chemicalComponents/ccd.pickle \
     https://services.healthtech.dtu.dk/suppl/immunology/NetTCRaFold-1.0/chemicalComponents/chemical_component_sets.pickle
   ```

5. Download the curated databases:
   ```
   wget -r -np -nH --cut-dirs=3 -R "index.html*" -P alphafold3_tcrpmhc/ \
     https://services.healthtech.dtu.dk/suppl/immunology/NetTCRaFold-1.0/tcrpmhc_databases/
   ```

6. Install DockQ (version 1.0):
   ```
   git clone git@github.com:wallnerlab/DockQ.git
   cd DockQ
   git checkout 3735c16
   ```

7. Create the conda environment for running the pipeline (its pip section already installs this package editable, so no separate `pip install -e` is needed):
   ```
   conda env create -f pipeline/NetTCRfold.yml
   conda activate NetTCRfold
   ```

`install.sh` runs steps 3-7 automatically (step 2 can't be scripted — it requires manually requesting access).

### Common setup errors

- **Missing apptainer image**: `FATAL: While checking container encryption: could not open image ... .sif: ... no such file or directory` in `examples/logs/af3_datageneration_workflow/*.err` → re-run step 3 above.
- **Missing weights**: `FATAL: container creation failed: mount hook function failure: mount .../alphafold3_tcrpmhc/weights->/mnt/models error: ... mount source .../weights doesn't exist` → complete step 2 above.
- **Missing databases**: `FATAL: container creation failed: mount hook function failure: mount .../alphafold3_tcrpmhc/tcrpmhc_databases->... doesn't exist` → re-run step 5 above.

## Advanced: config file reference

### env.cfg

Machine/install-specific paths, sourced once at the top of `workflow.sh`. Copy `configs/envExample.cfg` to `configs/env.cfg` and fill in:

- `PROJECT_ROOT`: path to this repository.
- `CONDA_SH`: path to your conda installation's `etc/profile.d/conda.sh` (needed so `workflow.sh` can `conda activate` inside a non-interactive SLURM job).
- `DOCKQ_REPO`: path to the DockQ v1.0 checkout (step 6 above).
- `AF3_RESOURCES_DIR`: path to `alphafold3_tcrpmhc` (weights, databases).
- `AF3_IMAGE`: path to the apptainer `.sif` image.

### config.cfg

Which steps to run and how. `workflow.sh` takes the config path as its first argument (`sbatch workflow.sh configs/your.cfg`, defaults to `configs/config.cfg`). Start from `configs/configMinimal.cfg` (required fields only) or `configs/config.cfg` (all fields, for reference). Fields with a listed default are optional and can be omitted.

**Step selection** (all required — pick `true`/`false` for each):
- `RUN_JSON_WITH_MSA_TEMPLATE_GENERATION`, `RUN_DATA_GENERATION_PIPELINE`, `RUN_CUSTOM_JSON_GENERATION`, `RUN_AF3_INFERENCE`, `COMPUTE_DOCKQ`, `RUN_METRICS_COLLECTION`.

**Slurm array sizing** (optional, default `1` each):
- `CONCURRENT`: max concurrent array tasks for the data generation step.
- `CONCURRENT_INFERENCE`: max concurrent array tasks for the inference step.
- `GLOBAL_START` (default `1`): array index to start submitting from.

**Preprocessing step** (`RUN_JSON_WITH_MSA_TEMPLATE_GENERATION`):
- `DATA_DIR` (required): base path holding the input CSV; also where all pipeline outputs for this run are written, in subfolders.
- `INPUT_FILE` (required): path to the input CSV, relative to `DATA_DIR`.
- `SUFFIX_DATAGEN` (optional, default none): suffix appended to the data-generation output folder — useful when running multiple settings (e.g. different databases) for the same input.

**AF3 data generation step** (`RUN_DATA_GENERATION_PIPELINE`):
- `TEMPLATE_SELECTION_METHOD` (optional, default `onquery`): space-separated list of `onquery`/`standard` methods to run.

**Custom JSON generation step** (`RUN_CUSTOM_JSON_GENERATION`):
- `MSA_TEMPLATE_COMBINATIONS` (optional, default `unpaired_onquery`): space-separated `<msaMode>_<templateMode>` combinations to reconstruct. `msaMode`: `unpaired`/`paired`/`full`/`no`. `templateMode`: `onquery`/`standard`/`no`.

**AF3 structure inference step** (`RUN_AF3_INFERENCE`):
- `FOLDERS_INFERENCE` (optional, default: all folders under `jsonFiles/customJSON`): space-separated folder names to run inference on.
- `SUFFIX_OUTPUT` (optional, default none): suffix appended to the inference output folder.
- `NUM_SEEDS` (optional, default `1`): number of seeds per datapoint.
- `NUM_DIFFUSION` (optional, default `5`): number of diffusion samples per seed.

**DockQ computation** (`COMPUTE_DOCKQ`):
- `TEMPLATE_PATH` (required if `COMPUTE_DOCKQ=true`): folder of solved-structure templates, truncated the same way as the inputs, named `{pdb_id}.trunc.fit.pdb` matching each model's `pdb_id`.

**Metrics collection** (`RUN_METRICS_COLLECTION`):
- `FOLDERS_METRIC_COLLECTION` (optional, default: all folders under the inference output): space-separated folder names to collect metrics for.
- `NUM_METRIC_SPLITS` (optional, default `1`): number of parallel SLURM array tasks to split metrics collection into.
- `CONCURRENT_METRICS` (optional, default `1`): max concurrent tasks from `NUM_METRIC_SPLITS`.

## Advanced: scripts reference

Each pipeline step is backed by one or more standalone scripts, in case you want to call them directly instead of going through `workflow.sh`.

**1. Data preprocessing** — `NetTCRfold.jsonPrep.dataPreprocessing`
- `-i`: input CSV (see [input data format](#preparing-your-own-input-data)).
- `-o`: output folder.
- `-m`: MHC database, used to infer allele sequences when `MHCA_aa` isn't given.
- Outputs: `{input_file}_hla_withid.csv` (input + assigned HLA + unique chain IDs); `chainid_to_array.txt` and `samplename_to_array.txt` (SLURM array index maps); `jsonFiles/json_msa_template/` (one folder per unique chain, AF3-format input).

**2. Data generation** — `runAF3_dataGeneration.sh` (positional args): `config` (`chainid_to_array.txt`), `json_path` (`json_msa_template/`), `output_dir`, `logs_path`, `template_selection_method`, `start_id`.

**3. Custom JSON generation** — `NetTCRfold.jsonPrep.create_custom_json`
- `-i`: data-generation output folder (`dataPipelineOut{suffix}`).
- `-o`: output folder for reconstructed JSON (`jsonFiles/customJSON`).
- `-d`: path to `{input_file}_hla_withid.csv` from step 1.
- `-c`: combinations string to reconstruct.

**4. AF3 inference** — `runAF3_inference.sh` (positional args): `folder_path` (JSON files to process), `output_inference`, `logs_path`, `ARRAY_MAP_INFERENCE` (`samplename_to_array.txt`), `NUM_SEEDS`, `NUM_DIFFUSION`, `start`.

**5. DockQ** — `NetTCRfold.metrics.computeDockq`
- `-i`: folder of `pdb_id`s to process (inference output).
- `-t`: template path (solved structures).
- `-d`: path to the DockQ v1.0 repo.
- `-n1`/`-m1`: TCR chain names in the native/model structure.
- `-n2`/`-m2`: pMHC chain names in the native/model structure.
- `-s`: suffix appended to output filenames.
- Output: writes DockQ results into each `pdb_id`/`sample_seed` folder.

**6. Metrics collection** — three scripts run in sequence:
- `NetTCRfold.metrics.collect_af3metrics_extended_parallel` (called via `collect_metrics_slurm_parallel.sh`): `-i` folder to evaluate, `-s` suffix, `--split_idx`/`--num_splits` for parallel splitting. DockQ is picked up automatically from `dockQ_metrics_*.json` files found on disk, independent of `-s` — so this works whether or not DockQ was computed in the same run. Output: `collected_af3metrics{suffix}.csv` per folder.
- `NetTCRfold.metrics.combine_metrics_onefile`: `-i` the general inference output folder, `-s` suffix. Output: `allresults_merged{suffix}.csv`, combining all folders.
- `NetTCRfold.metrics.expandMetrics`: `-i`/`--input_csv` the `allresults_merged{suffix}.csv` above, `-o`/`--output_csv` output path. Flattens the nested per-chain-pair metric dictionaries (`chain_pair_iptm`, `chain_pair_pae_min`, `cdr_metric_mean_chain`, `ipsae`, `ipsae_d0chn`, `ipsae_d0dom`) into one column per chain pair (e.g. `TRA_TRB_ipsae`). Output: `allresults_merged_expanded{suffix}.csv`.
