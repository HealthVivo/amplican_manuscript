rm(list=ls(all = TRUE))
gc(reset=TRUE)

mut_frac <- c(0.1, 0.2, 0.3)
sim <- paste0("simulation_", mut_frac)

library("GenomicRanges")
library("Biostrings")
library("rtracklayer")
library(BSgenome.Drerio.UCSC.danRer7)

danRer7 <- BSgenome.Drerio.UCSC.danRer7

randACTG <- function(width) {
  ins <- sample(c("A","C","T","G"), width, replace = TRUE)
  paste0(ins, collapse = "")
}

deleteNucleotides <- function(original, original_range, start, width){
    y <- IRanges(start, width = width)
    result <- original[setdiff(disjoin(c(y,original_range)), y)]
    result
}

insertNucleotides <- function(original, original_range, start, width){
  ins <- sample(c("A","C","T","G"), width, replace = TRUE)
  ins <- paste0(ins, collapse = "")
  rngs <- IRanges(c(1,start+1), end = c(start, width(original_range)))
  sqs <- as.character(Views(original, rngs))
  result <- DNAString(paste0(c(sqs[1], ins,sqs[2]), collapse = ""))
  result
}

mutateNucleotides <- function(original, fraction){
  nsample <- floor(fraction*length(original))
  mutate <- sample(c(1:length(original)), nsample)
  nucs <- strsplit(as.character(original),"")[[1]]
  replace_nucs <- list("A" = c("C","G","T"), "C" = c("A","G","T"),
                       "T" = c("A","C","G"), "G" = c("A","C","T"))
  replace_idx <- sample(c(1,2,3), nsample, replace = TRUE)
  replace_idx <- replace_idx + seq(0, 3*(nsample-1), by = 3)
  new_nucs <- unlist(replace_nucs[nucs[mutate]])[replace_idx]
  nucs[mutate] <- new_nucs
  paste0(nucs, collapse = "")
}

set.seed(30)

for (w in seq_along(sim)) { # iterate over simulations

freqs <- read.table("./idx/Shah_mutation_weights.txt", sep = "\t")
# Set a low value for large indels
freqs$x[freqs$Variant > 10] <- 1e-10
freqs$x <- freqs$x/sum(freqs$x)

read_lengths <- 150 + 40 # for deletions
read_lengths_illumina <- read_lengths - 40

amplicons <- read.table("./idx/Shah_cut_sites.txt", sep = "\t",
                        stringsAsFactors = FALSE)
colnames(amplicons) <- c("name","original","target_loc")
amplicons[,"target_loc"] <- as.integer(amplicons[,"target_loc"])
amplicons <- amplicons[1:20,]

# Get guides for ampliconDIVider
guides_loc <- rtracklayer::import("./idx/shah_guides.bed")
guides_loc <- guides_loc[match(amplicons$name, guides_loc$name)]
guides <- guides_loc + 5
adiv_out <- paste0("./real_offtargets/amplicondivider_", sim[w], "_commands.sh")
cat('cd ../software/ampliconDIVider-master\nsource ampliconDIV_minimal.sh\n',
    file = adiv_out)

# get guideRNA locations + 5 for CRISPRPooled
guide <- as.character(getSeq(danRer7, guides_loc))

# get new amplicons with centered guides
extra_bases <- ceiling((read_lengths - 23 - 20 - 20) / 2)
ampl_start <- start(guides_loc) - 20 - extra_bases
ampl_end <- end(guides_loc) + 20 + extra_bases + 1
ampl <- guides_loc
start(ampl) <- ampl_start
end(ampl) <- ampl_end
ampl <- getSeq(danRer7, ampl)
ampl_target_loc <- 20 + extra_bases + 17

amplicon_inf <- paste(amplicons$name, as.character(ampl), guide, sep = "\t", collapse = "\n")
cat(amplicon_inf, file = paste0("./real_offtargets/", sim[w], "/merged/crispresso_pooled_amplicons.txt"))
if (!all(nchar(ampl) > read_lengths)) stop("sizes!")

amplicons <- data.frame(name = as.character(amplicons$name),
                        original = as.character(ampl),
                        target_loc = ampl_target_loc)
# make amplican config file
ampl_conf <- data.table::fread("./real_offtargets/config_merged.csv")
ampl_conf$V11 <- paste0(
  tolower(substr(ampl, 1, 20 + extra_bases)),
  toupper(substr(ampl, 20 + extra_bases + 1, 20 + extra_bases + 23)),
  tolower(substr(ampl, 20 + extra_bases + 23 + 1, nchar(ampl))))
ampl_conf$V7 <- guide
ampl_conf$V8 <- toupper(substr(ampl, 1, 20))
ampl_conf$V9 <- toupper(reverseComplement(DNAStringSet(substr(ampl, nchar(ampl) - 19, nchar(ampl)))))
ampl_conf$Donor <- ""
data.table::fwrite(ampl_conf, "./real_offtargets/config_merged.csv")

sample_seqs <- function(n_mut, n_original, n_offtarget, amplicons,
                        out_dir, sim_file, mut_frac = mut_frac[w],
                        log_file = NA, nvars = 10, crispresso_file =  NA,
                        read_len = 150){

  for (i in 1:nrow(amplicons)) {
    a_rw <- amplicons[i, ]
    original <- DNAString(a_rw$original)
    target_loc <- as.integer(a_rw["target_loc"])
    gd_name <- as.character(a_rw$name)
    guide <- substr(original, target_loc-17, target_loc + 5)
    original_range <- IRanges(1, length(original))
    amp_loc <- target_loc + freqs$Location - 1
    subsamp <- sample(1:nrow(freqs), nvars, prob = freqs$x)
    row_idxs <- sample(c(1:nrow(freqs))[subsamp], n_mut,
                  prob = freqs$x[subsamp], replace = TRUE)

    subf <- freqs[subsamp,]
    var_labs <- paste(subf$Location, paste0(subf$Variant, subf$var_type), sep = ":")
    var_freqs <- table(factor(row_idxs, levels = subsamp))
    names(var_freqs) <- var_labs

    new_seqs <- lapply(row_idxs, function(i){
      rw <- freqs[i,]
      if (rw$var_type == "D") func <- deleteNucleotides
      if (rw$var_type == "I") func <- insertNucleotides
      new_seq <-  func(original, original_range, amp_loc[i], rw$Variant)
      new_seq
    })

    mut_seqs <- lapply(seq_len(n_offtarget), function(i) paste0(
      original[1:20],
      mutateNucleotides(original[21:(nchar(original) - 21)], mut_frac),
      original[(nchar(original) - 20):nchar(original)]))

    out_fname <- file.path(out_dir, sprintf("%s_%smut_%swt_%sofftarget_%sreadlen.fa",
                  gd_name, n_mut, n_original, n_offtarget, read_len))

    result <- c(new_seqs, mut_seqs, replicate(n_original, original))
    result_names <- c(rep(">var", n_mut),
                      rep(">offtarget", n_offtarget),
                      rep(">original", n_original))

    print(sprintf("Length variant: %s Length unmutated: %s Length offtarget %s",
          length(new_seqs), n_original, length(mut_seqs)))
    stopifnot(length(result_names) == (length(new_seqs)+ length(mut_seqs) + n_original))

    result_names <- paste(result_names, c(seq_len(n_mut),
                           seq_len(n_offtarget), seq_len(n_original)), sep = "_")

    new_seqs <- paste(result_names, sapply(result, as.character), sep = "\n")
    new_seqs <- paste0(new_seqs, collapse = "\n")
    print(sprintf("Writing sequences to: %s", out_fname))
    cat(new_seqs, file = out_fname)

    # art_illumina command with seed = 30
    sim_template <- "art_illumina -amp -rs 30 -f 10 -l %s -p -ss MSv1 -na -i %s -o %s\n"
    cat(sprintf(sim_template, read_len, out_fname, gsub(".fa", "_sim", out_fname)),
        file = sim_file, append = TRUE)

    # Commands for CRISPResso
    f1 <- gsub(".fa", "_sim1.fq", out_fname)
    f2 <- gsub(".fa", "_sim2.fq", out_fname)
    crispresso_dir <- "crispresso"
    crispresso_template <- "CRISPResso -r1 %s -r2 %s -a %s -g %s -o %s -w 5\n"
    cat(sprintf(crispresso_template, f1,f2, original, guide, crispresso_dir),
        file = crispresso_file, append = TRUE)

    # Commands for ampliconDIVider
    adiv_dir <- paste0("../../analysis/real_offtargets/", sim[w], "/amplicondivider")
    adiv_tmp1 <- 'samtools view -hb %s %s > temp.bam'
    adiv_tmp2 <- 'parseBam temp.bam %s %s %s; rm temp.bam'
    adiv_tmp3 <- 'mv frameshift_summary_%s %s\n\n'
    bam <- gsub(".fa", "_merged.bam", out_fname)
    gd <- guides[i]
    gd_rng <- sprintf("%s:%s-%s", seqnames(gd), start(gd)-200, end(gd)+200)
    base <- gsub(".fa", "", basename(out_fname))
    a1 <- sprintf(adiv_tmp1, file.path("../../analysis/real_offtargets/", sim[w], basename(bam)), gd_rng)
    a2 <- sprintf(adiv_tmp2, base, start(gd) - 5, end(gd) + 5)
    a3 <- sprintf(adiv_tmp3, base, file.path(adiv_dir, paste0(base, ".txt")))
    cat(paste(a1,a2,a3, sep = "\n"), file = adiv_out, append = TRUE)
  }
}

sim_cmds <- paste0("./real_offtargets/", sim[w], "_commands.sh")
crispresso_cmds <- paste0("./real_offtargets/crispresso_", sim[w], "_commands.sh")

for (nofftargets in c(100,33,0)){
  # cntn3b_0mut_300wt_100offtarget_200readlen.fa
    # 0% efficient
    sample_seqs(0,300, nofftargets, amplicons, paste0("./real_offtargets/", sim[w]),
               sim_file = sim_cmds, crispresso_file = crispresso_cmds, mut_frac = mut_frac[w])

    # 33% efficient
    sample_seqs(100,200, nofftargets, amplicons, paste0("./real_offtargets/", sim[w]),
               sim_file = sim_cmds, crispresso_file = crispresso_cmds, mut_frac = mut_frac[w])

    # 66% efficient
    sample_seqs(200,100, nofftargets, amplicons, paste0("./real_offtargets/", sim[w]),
               sim_file = sim_cmds, crispresso_file = crispresso_cmds, mut_frac = mut_frac[w])

    # 90% efficient
    sample_seqs(270,30, nofftargets, amplicons, paste0("./real_offtargets/", sim[w]),
               sim_file = sim_cmds, crispresso_file = crispresso_cmds, mut_frac = mut_frac[w])
}

cat(paste0("\n\nmv crispresso/* ./real_offtargets/", sim[w], "/crispresso; rmdir crispresso\n"),
    file = crispresso_cmds, append = TRUE)

}
