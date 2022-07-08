// Use DSL 2
nextflow.enable.dsl = 2

// Define optional parameters
params.formula = "NA"
params.threshold = 3
params.B = 1000
params.side = "both"
params.gene_pod_size = 50
params.grna_group_pod_size = 50
params.pair_pod_size = 100
params.n_pairs_to_sample = 0
params.result_fp = "$PWD/sceptre_result.rds"
params.gene_modality_name = "gene"
params.grna_modality_name = "grna"

// Mild command line argument processing
// 1. Obtain the base name of directory of file to write
File out_f = new File(params.result_fp)
result_file_name = out_f.getName()
result_dir = out_f.getAbsoluteFile().getParent()

// 2. Replace formula parens with slash parens
formula = params.formula.replaceAll("\\(", "\\\\(").replaceAll("\\)", "\\\\)")

// PROCESS 1: Check inputs; output the list of gene IDs and grna groups
process check_inputs {
  debug true

  time "5m"
  memory "2 GB"

  input:
  path multimodal_metadata_fp
  path "gene_odm_fp"
  path "grna_odm_fp"
  path pair_fp

  //output:
  //path "gene_ids.txt", emit: gene_ids_names_ch_raw
  //path "grna_groups.txt", emit: grna_groups_names_ch_raw
  //path "pairs.txt", emit: pair_names_ch_raw
  //path "mm_odm_new.rds", emit: multimodal_metadata_ch

  //"""
  //check_inputs.R $multimodal_metadata_fp $gene_odm_fp $grna_odm_fp $pair_fp $formula $params.threshold $params.B $params.side $params.n_pairs_to_sample $params.gene_modality_name $params.grna_modality_name
  //"""

  """
  echo $multimodal_metadata_fp $gene_odm_fp $grna_odm_fp $pair_fp $formula $params.threshold $params.B $params.side $params.n_pairs_to_sample $params.gene_modality_name $params.grna_modality_name
  """
}

// PROCESS 2: Perform gene precomputation
process perform_gene_precomputation {
  time { 30.s * params.gene_pod_size }
  memory "2 GB"

  input:
  path multimodal_metadata_fp
  path gene_odm_fp
  path grna_odm_fp
  val gene_ids

  output:
  path "*.rds"

  """
  perform_precomputation.R "gene" $multimodal_metadata_fp $gene_odm_fp $grna_odm_fp $gene_ids
  """
}

// PROCESS 3: Perform grna precomputation
process perform_grna_precomputation {
  time { 30.s * params.grna_group_pod_size }
  memory "2 GB"

  input:
  path multimodal_metadata_fp
  path gene_odm_fp
  path grna_odm_fp
  val gene_ids

  output:
  path "*.rds"

  """
  perform_precomputation.R "grna" $multimodal_metadata_fp $gene_odm_fp $grna_odm_fp $gene_ids
  """
}

// PROCESS 4: Perform pairwise association test
process perform_pairwise_association_test {
  time { 30.s * params.pair_pod_size }
  memory "2 GB"

  input:
  path multimodal_metadata_fp
  path gene_odm_fp
  path grna_odm_fp
  tuple val(gene_id), val(grna_id), path('gene_fp'), path('grna_fp')

  output:
  path "raw_result.rds"

  """
  run_association_test.R $multimodal_metadata_fp $gene_odm_fp $grna_odm_fp $gene_id $grna_id gene_fp* grna_fp*
  """
}

// PROCESS 5: Combine results
process combine_results {
  time "5m"
  memory "2 GB"

  publishDir result_dir, mode: "copy"

  output:
  path "$result_file_name"

  input:
  path "raw_result"
  path pair_fp

  """
  combine_results.R $result_file_name $pair_fp raw_result*
  """
}

// Define useful Groovy functions
def my_spread(elem_list, j) {
  out = []
  for (elem in elem_list) {
    out.add(elem[j])
  }
  return out
}

def my_spread_str(elem_list, j) {
  l_size = elem_list.size();
  out = ""
  for (i = 0; i < l_size; i ++) {
    elem = elem_list[i]
    out += (elem[j] + (i == l_size - 1 ? "" : " "))
  }
  return out
}

// Define the workflow (DO NOT MODIFY)
workflow {
  // Step 1: Check inputs for correctness; output channels for gene IDs, grna groups, and pairs
  check_inputs(params.multimodal_metadata_fp,
               params.gene_odm_fp,
               params.grna_odm_fp,
               params.pair_fp)
  /*
  // Step 2: Clean up the gene, grna, and pair output channels; collate the former two
  gene_ids_ch = check_inputs.out.gene_ids_names_ch_raw.splitText().map{it.trim()}.collate(params.gene_pod_size).map{it.join(' ')}
  grna_groups_ch = check_inputs.out.grna_groups_names_ch_raw.splitText().map{it.trim()}.collate(params.gene_pod_size).map{it.join(' ')}
  pair_names_ch = check_inputs.out.pair_names_ch_raw.splitText().map{it.trim()}
  multimodal_metadata_ch = check_inputs.out.multimodal_metadata_ch

  // STEP 3: Perform the precomputation on genes
  perform_gene_precomputation(multimodal_metadata_ch,
                              params.gene_odm_fp,
                              params.grna_odm_fp,
                              gene_ids_ch)
  gene_precomp_ch_raw = perform_gene_precomputation.out


  // STEP 4: Perform the precomputation on grna groups
  perform_grna_precomputation(multimodal_metadata_ch,
                              params.gene_odm_fp,
                              params.grna_odm_fp,
                              grna_groups_ch)
  grna_precomp_ch_raw = perform_grna_precomputation.out

  // Step 5: Add the gene and grna precomputation locations to the gene-grna pairs
  gene_precomp_ch = gene_precomp_ch_raw.flatten().map{file -> tuple(file.baseName, file)}
  grna_precomp_ch = grna_precomp_ch_raw.flatten().map{file -> tuple(file.baseName, file)}
  pair_ch = pair_names_ch.map{split = it.split(" "); [split[0], split[1]]}
  all_pair_genes_labelled_ch = gene_precomp_ch.cross(pair_ch).map{[it[1][1], it[1][0], it[0][1]]}
  all_pairs_labelled_ch = grna_precomp_ch.cross(all_pair_genes_labelled_ch).map{[it[1][1], it[1][0], it[1][2], it[0][1]]}.collate(params.pair_pod_size)
  all_pairs_labelled_ordered = all_pairs_labelled_ch.map{[my_spread_str(it, 0), my_spread_str(it, 1), my_spread(it, 2), my_spread(it, 3)]}

  // Step 6: Perform the pairwise association test
  perform_pairwise_association_test(multimodal_metadata_ch,
                                    params.gene_odm_fp,
                                    params.grna_odm_fp,
                                    all_pairs_labelled_ordered)

  // Step 7: Gather the results
  combine_results(perform_pairwise_association_test.out.collect(),
                  params.pair_fp)
  */
}