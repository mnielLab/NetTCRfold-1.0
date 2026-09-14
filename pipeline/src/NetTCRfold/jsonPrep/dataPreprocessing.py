import pandas as pd
import argparse
import os
from pathlib import Path
import json
import re

def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "-i",
        "--input",
        type=Path,
        required=True,
        help="Path to the csv input file with query data",
    )
    parser.add_argument(
        "-o",
        "--output",
        type=Path,
        required=True,
        help="Path to the output file with the results",
    )
    parser.add_argument(
        "-m",
        "--mhc-db",
        type=Path,
        required=True,
        help="Path to the folder with MHC sequence JSON files (databases/mhc_sequences)",
    )
    return parser.parse_args()


def samplename_to_array(df, output_path):
    if "name" not in df.columns:
        raise ValueError(
            f"Input file must contain a 'name' column. "
            f"Found columns: {list(df.columns)}"
        )
    sample_names = df['name'].unique()
    output_df = pd.DataFrame({
        'ArrayTaskID': range(1, len(sample_names)+1),
        'SampleName': sample_names
    })

    output_df.to_csv(f"{output_path}/samplename_to_array.txt", sep='\t', index=False)

def chainid_to_array(df, output_path):
    sample_names_TRA = df['TRA_aa_id'].unique().tolist()
    sample_names_TRB = df['TRB_aa_id'].unique().tolist()
    sample_names_MHC = df['MHCA_aa_id'].unique().tolist()
    if "MHCB_aa_id" in df.columns:
        sample_names_MHCB = df['MHCB_aa_id'].dropna().unique().tolist()
    else:
        sample_names_MHCB = []
    
    sample_names = sample_names_TRA + sample_names_TRB + sample_names_MHC + sample_names_MHCB
    output_df = pd.DataFrame({
        'ArrayTaskID': range(1, len(sample_names)+1),
        'SampleName': sample_names
    })

    output_df.to_csv(f"{output_path}/chainid_to_array.txt", sep='\t', index=False)


def get_mhc_sequence(
    allele: str,
    data_dir: Path,
) -> str:
    """Returns the amino acid sequence of an MHC allele.

    Args:
        allele: MHC allele name.
        data_dir: Path to the folder with MHC sequence JSON files.

    Returns:
        Amino acid sequence of the MHC allele.
    """

    # grab the gene name
    gene = re.search(r"([A-Z])\*.*", allele).group(1)
    with open(data_dir / f"{gene}_prot.json") as f:
        data = json.load(f)

    # default to 01 for missing fields
    num_fields = len(allele.split(":"))
    allele = allele + ":01" * (4 - num_fields)

    # grab the sequence
    try:
        seq = data[allele]
    except KeyError:
        raise KeyError(f"Allele {allele} not found in {data_dir}")
    return seq


def json_af3(df, output, msa=True):
    
    elements = ["TRA_aa", "TRB_aa", "MHCA_aa"]
    #elements = []
    id_dict = {"TRA_aa" : "D" , 
                "TRB_aa": "E", 
                "MHCA_aa": "A"}
    if "MHCB_aa" in df.columns and df["MHCB_aa"].notna().any():
        elements.append("MHCB_aa")
        id_dict["MHCB_aa"] = "B"

    for element_name in elements:
        
        # if element_name == "MHC_aa":
        #     col_id = "allele"
        # else:
        col_id = f"{element_name}_id"
        
        df_elements = (
            df[[element_name, col_id]]
            .dropna()
            .drop_duplicates()
        )
        
        for idx, row in df_elements.iterrows():
            jsonf = {}
            jsonf["name"] = row[col_id]
            proteins = []
            if msa:
                protein = {
                    "protein": {
                        "id": id_dict[element_name],
                        "sequence": row[element_name]
                    }
                }
                proteins.append(protein)
                output_folder ="json_msa_template/"
            else:
                protein = {
                    "protein": {
                        "id": id_dict[element_name],
                        "sequence": row[element_name],
                        "unpairedMsa": "",
                        "pairedMsa": ""
                    }
                }
                proteins.append(protein)
                output_folder ="json_nomsa_template/"

            jsonf["sequences"] = proteins
            jsonf["modelSeeds"] = [1]
            jsonf["dialect"] = "alphafold3"
            jsonf["version"] = 1

            output_dir = output / output_folder / row[col_id]
            output_dir.mkdir(parents=True, exist_ok=True)
            with open(output_dir / "alphafold_input.json", "w") as f:
                json.dump(jsonf, f, indent=4)


def main() -> None:
    """Main entry point to modeling pipeline."""
    args = parse_args()
    input_csv = args.input
    output_path = args.output
    output_path.mkdir(parents=True, exist_ok=True)
    df = pd.read_csv(input_csv)
   
    if "epitope_aa" in df.columns:
        df = df.rename(columns={"epitope_aa": "peptide"})

    if "name" not in df.columns:
        if "pdb_id" in df.columns:
            df["name"] = df["pdb_id"]
        else:
            if not all(col in df.columns for col in ["peptide", "A1", "A2", "A3", "B1", "B2", "B3"]):
                #Try the TRA_aa format
                if not all(col in df.columns for col in ["peptide", "TRA_aa", "TRB_aa"]):
                    raise ValueError(
                        f"Input file must contain a 'name' column or the columns to create it.\n This is either peptide, CDR1a, CDR2a, CDR3a, CDR1b, CDR2b, CDR3b or peptide, TRA_aa, TRB_aa.\n"
                        f"Found columns: {list(df.columns)}"
                    )
                else:
                    df["name"] = df["peptide"] + "_" + df["TRA_aa"] + "_" + df["TRB_aa"]
                    print("Unique identifier will be created using peptide, TRA_aa and TRB_aa columns.")
            else:
                df["name"] = df["peptide"] + "_" + df["A1"] + "_" + df["A2"] + "_" + df["A3"] + "_" + df["B1"] + "_" + df["B2"] + "_" + df["B3"] 
                print("Unique identifier will be created using peptide, A1, A2, A3, B1, B2 and B3 columns.")
    if "MHCA_aa" not in df.columns:
        if "allele" in df.columns:
            df["MHCA_aa"] = df["allele"].map(
                {allele: get_mhc_sequence(allele, args.mhc_db) for allele in df["allele"].unique()}
            )
        elif "HLA" in df.columns:
            df["MHCA_aa"] = df["HLA"].map(
                {allele: get_mhc_sequence(allele, args.mhc_db) for allele in df["HLA"].unique()}
            )
        else:
            raise ValueError(
                f"Input file must contain a 'MHCA_aa' column or the columns to create it.\n This is either allele or HLA.\n"
                f"Found columns: {list(df.columns)}"
            )


    df["TRA_aa_id"] = "TRA_" + df["TRA_aa"].astype("category").cat.codes.astype(str)
    df["TRB_aa_id"] =  "TRB_" + df["TRB_aa"].astype("category").cat.codes.astype(str)
    df["MHCA_aa_id"] = "MHCA_" + df["MHCA_aa"].astype("category").cat.codes.astype(str)
    if "MHCB_aa" in df.columns and df["MHCB_aa"].notna().any():
        mask = df["MHCB_aa"].notna()
        df.loc[mask, "MHCB_aa_id"] = ("MHCB_" + df.loc[mask, "MHCB_aa"].astype("category").cat.codes.astype(str))

    samplename_to_array(df, output_path)
    chainid_to_array(df, output_path)
    df.to_csv(Path(output_path/ f"{Path(input_csv).stem}_hla_withid.csv"))
    
    json_af3(df, Path(output_path / "jsonFiles/"))

if __name__ == "__main__":
    main()


