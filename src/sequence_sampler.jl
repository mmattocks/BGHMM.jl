#BASIC COORDINATE FUNCTIONS
# function to push scaffold ID, start, and end points of given featuretype to supplied dataframe
function build_feature_df!(GFF3_path::String, feature_type::String, scaffold_exclusion::String, feature_df::DataFrame)
    reader = open(GFF3.Reader, GFF3_path) # access the GFF3
    @inbounds for record in reader # iterate over Gff3 records
        if GFF3.isfeature(record) # if the record is a feature
            if GFF3.featuretype(record) == feature_type #if the features is of the requested type, get the following info
                seqID = GFF3.seqid(record)
                if seqID != scaffold_exclusion
                    seq_start = GFF3.seqstart(record)
                    seq_end = GFF3.seqend(record)
                    if feature_type == "exon" || feature_type == "gene"
                        seq_strand = convert(Char, GFF3.strand(record))
                        push!(feature_df, [seqID, seq_start, seq_end, seq_strand])
                    else
                        push!(feature_df, [seqID, seq_start, seq_end]) # push relevant info to the df
                    end
                end
            end
        end
    end
    close(reader)
end

#function to assemble dataframe of scaffold coords + metacoords given gff3
function build_scaffold_df(gff3_path)
    DataFrame(SeqID = String[], Start = Int64[], End = Int64[])
    build_feature_df!(gff3_path, "supercontig", "MT", scaffold_df)
    build_feature_df!(gff3_path, "chromosome", "MT", scaffold_df)
    add_metacoordinates!(scaffold_df)
    return scaffold_df
end

#function to add pad to either side of some featureset
function add_pad_to_coordinates!(feature_df::DataFrame, scaffold_df::DataFrame, pad_size::Int64)
    pad_start_array = zeros(Int64,size(feature_df,1))
    pad_end_array = zeros(Int64,size(feature_df,1))
    feature_df.Start = [max(feature_df.Start[i]-pad_size,1) for i in 1:size(feature_df,1)] #truncate pads at beginning and end of scaffolds
    feature_df.End = [min(feature_df.End[i]+pad_size,scaffold_df.End[findfirst(isequal(feature_df.SeqID[i]),scaffold_df.SeqID)]) for i in 1:size(feature_df,1)]
end

#METACOORDINATE FUNCTIONS
# function to add a metacoordinate column to a dataframe of scaffold positions, allowing sampling across all scaffolds
function add_metacoordinates!(feature_df::DataFrame)
    meta_start_array = Int64[]
    meta_end_array = Int64[]
    metaposition = 1
    @inbounds for feature in eachrow(feature_df)
        push!(meta_start_array, (metaposition))
        metaposition += feature.End - feature.Start
        push!(meta_end_array, (metaposition))
        metaposition += 1
    end
    feature_df.MetaStart = meta_start_array # metacoordinate contains 'start' metaposition across all genomic material
    feature_df.MetaEnd = meta_end_array # metacoordinate contains 'end' metaposition across all genomic material
end

function get_feature_row_index(feature_df::DataFrame, metacoordinate::Int64)
    total_feature_bases = feature_df.MetaEnd[end]
    if metacoordinate == total_feature_bases #edge case of metacoord at end of range
        return size(feature_df,1) #last index in df
    else
        index = findfirst(coord->coord>metacoordinate,feature_df.MetaEnd)
        if metacoordinate == feature_df.MetaEnd[index-1]
            return index-1
        elseif metacoordinate >= feature_df.MetaStart[index] && metacoordinate <= feature_df.MetaEnd[index]
            return index
        else
            @error "Unexpected metacoordinate $metacoordinate in partition of $total_feature_bases bases, with feature start $(feature_df.MetaStart[index]), end $(feature_df.MetaEnd[index])"
        end
    end
end

# function to get the seqID associated wtih a metacoordinate
function get_metacoord_scaffold(feature_df::DataFrame, metacoordinate::Int64)
    feature_row = get_feature_row_index(feature_df, metacoordinate)
    metacoord_scaffold = feature_df.SeqID[feature_row]
    return metacoord_scaffold
end

# function to convert metacoordinate set to scaffold-relative coordinates
function meta_to_feature_coord(meta_start::Int64, meta_end::Int64, feature_df::DataFrame)
    feature_row = get_feature_row_index(feature_df, meta_start)
    seqid = feature_df.SeqID[feature_row]
    scaffold_start = feature_df.Start[feature_row] + (meta_start - feature_df.MetaStart[feature_row])
    scaffold_end = feature_df.End[feature_row] - (feature_df.MetaEnd[feature_row] - meta_end)
    return seqid, scaffold_start, scaffold_end
end

#function to obtain the feature boundaries and strand of the feature that a metacoordinate falls within
function get_feature_params_from_metacoord(metacoordinate::Int64, feature_df::DataFrame, stranded::Bool)
    feature_row = get_feature_row_index(feature_df, metacoordinate)
    feature_metaStart = feature_df.MetaStart[feature_row]
    feature_metaEnd = feature_df.MetaEnd[feature_row]
    stranded ? feature_strand = feature_df.Strand[feature_row] : feature_strand = '0'
    return feature_metaStart, feature_metaEnd, feature_strand
end

#BITARRAY SCAFFOLD REPRESENTATION FUNCTIONS
function init_scaffold_bitarray(scaffold_id::String, scaffold_df, value::Bool; stranded::Bool=false)
    scaffold_length = scaffold_df.End[findfirst(isequal(scaffold_id), scaffold_df.SeqID)]
    if stranded
        value ? (return rscaffold_bitarray = trues(scaffold_length,2)) : (return rscaffold_bitarray = falses(scaffold_length,2))
    else
        value ? (return rscaffold_bitarray = trues(scaffold_length,1)) : (return rscaffold_bitarray = falses(scaffold_length,1))
    end
end

function project_features_to_bitarray!(scaffold_feature_sf::SubDataFrame, scaffold_bitarray::BitArray)
    for item in eachrow(scaffold_feature_sf)
        scaffold_bitarray[item.Start:item.End,1] = [true for base in item.Start:item.End]
        if size(scaffold_bitarray)[2] == 2 #if the bitarray is stranded
            if item.Strand == '+'
                scaffold_bitarray[item.Start:item.End,1] = [true for base in item.Start:item.End]
            end
        end
    end
end

function subtract_features_from_bitarray!(scaffold_feature_sf::DataFrame, scaffold_bitarray::BitArray)
    for item in eachrow(scaffold_feature_sf)
        scaffold_bitarray[item.Start:item.End,1] = [false for base in item.Start:item.End]
    end
end

function get_feature_df_from_bitarray(scaffold_id::String, scaffold_bitarray::BitArray)
    size(scaffold_bitarray)[2] == 2 ? scaffold_feature_df = DataFrame(SeqID = String[], Start = Int64[], End = Int64[], Strand=Char[]) : scaffold_feature_df = DataFrame(SeqID = String[], Start = Int64[], End = Int64[])

    new_feature_start = findnext(scaffold_bitarray[:,1], 1)
    while new_feature_start != nothing # while new features are still found on the bitarray
            if size(scaffold_bitarray)[2] == 2 #if stranded, get strand info
                scaffold_bitarray[new_feature_start,2] == 1 ? new_feature_strand = '+' : new_feature_strand = '-'
            end
            if findnext(!eval,scaffold_bitarray,new_feature_start) != nothing
                new_feature_end = findnext(!eval,scaffold_bitarray,new_feature_start)-1 #find next false after feature start and subtract 1 for feature end
            else
                new_feature_end = length(scaffold_bitarray) #if none is found, the end of the feature is the end of hte scaffold
            end
            size(scaffold_bitarray)[2] == 2 ? push!(scaffold_feature_df,[scaffold_id, new_feature_start, new_feature_end, new_feature_strand]) : push!(scaffold_feature_df,[scaffold_id, new_feature_start, new_feature_end]) #push stranded feature info as appropriate
            new_feature_start = findnext(scaffold_bitarray, new_feature_end+1)
    end
    return scaffold_feature_df
end

#SAMPLING FUNCTIONS
# function to check for repetitive stretches or degenerate bases in proposal sequence
function mask_check(proposal_sequence::DNASequence)
    proposal_acceptance = true
    if hasambiguity(proposal_sequence) || isrepetitive(proposal_sequence, (length(proposal_sequence) ÷ 10))
        proposal_acceptance = false
    end
    return proposal_acceptance
end

# function to get proposal sequence from genome reader, given coords and scaffold id
function fetch_sequence(scaffold_id::String, proposal_start::Int64, proposal_end::Int64, genome_reader::BioSequences.FASTA.Reader, sample_strand)
    identifier = rectify_identifier(scaffold_id)
    scaffold_record = genome_reader[identifier]
    strand_roll = 0
    if sample_strand == '0' #unstranded samples may be returned with no preference in either orientation
         strand_roll = rand(1)[1]
    end
    if sample_strand == '+' || (sample_strand == '0' && strand_roll > .5)
        proposal_sequence = DNASequence(sequence(scaffold_record)[proposal_start:proposal_end])
    else #if negative strand or unstranded with strand_roll <=.5
        proposal_sequence = reverse_complement(DNASequence(sequence(scaffold_record)[proposal_start:proposal_end]))
    end

    return proposal_sequence
end

# function to convert scaffold ID from GFF3 format to that observed by the masked .fna
function rectify_identifier(scaffold_id::String)
    numeric = true
    for char in scaffold_id #check if the id is entirely numeric
        if ! isnumeric(char)
            numeric=false
        end
    end
    if numeric
        id_base = 2884.2
        chr_no = parse(Int64, scaffold_id)
        return identifier = "CM00$(id_base+chr_no)"
    else
        return scaffold_id
    end
end

#function to find a valid sampling window
function determine_sample_window(feature_metaStart::Int64, feature_metaEnd::Int64, metacoord::Int64, metacoord_bitarray::BitArray, sample_window_min::Int64, sample_window_max::Int64)
    window_start = 0
    window_end = 0
    feature_size = feature_metaEnd - feature_metaStart + 1
    feature_sampled = any(!eval, metacoord_bitarray[feature_metaStart:feature_metaEnd])
    #attempt to construct the sample window by taking the whole feature
    if !feature_sampled && feature_size < sample_window_max && feature_size > sample_window_min
        window_start = feature_metaStart
        window_end = feature_metaEnd
        return window_start, window_end
    else #if this fails, build the biggest window we can from the sampling point, within the feature
        next_sampled_index = findnext(!eval, metacoord_bitarray[feature_metaStart:feature_metaEnd], metacoord-feature_metaStart+1)
        prev_sampled_index = findprev(!eval, metacoord_bitarray[feature_metaStart:feature_metaEnd], metacoord-feature_metaStart+1)
        next_sampled_index == nothing ? (window_end = feature_metaEnd) : (window_end = metacoord+next_sampled_index-1)
        prev_sampled_index == nothing ? (window_start = feature_metaStart) : (window_start = metacoord-prev_sampled_index+1)
        windowsize = window_end - window_start + 1
        #check to see if this window is bigger than the min, if not, return a failure code
        windowsize < sample_window_min && return "FAIL"
        #check to see if this window is bigger than the max, if so, trim it before returning, randomly chosing to trim 5' or 3'
        if windowsize > sample_window_max
            bases_to_trim = windowsize - sample_window_max
            trim_5prime=rand([true,false])
            if trim_5prime
                window_start += bases_to_trim
            else
                window_end -= bases_to_trim
            end
        end
        return window_start, window_end
    end
end

#function to produce a single sample from a metacoordinate set and the feature df
function get_sample(metacoordinate_bitarray::BitArray, sample_window_min::Int64, sample_window_max::Int64, partition_df::DataFrame, genome_reader::BioSequences.FASTA.Reader, partitionid::String; stranded::Bool=false)
    proposal_acceptance = false
    sample_metaStart = 0
    sample_metaEnd = 0
    sample_Start = 0
    sample_End = 0
    sample_sequence = DNASequence("")
    sample_scaffold = ""
    sample_strand = nothing
    while proposal_acceptance == false
        available_indices = findall(metacoordinate_bitarray) #find all unsampled indices
        window = "FAIL"
        while window == "FAIL"
            start_index = rand(available_indices) #randomly choose from the unsampled indices
            feature_metaStart, feature_metaEnd, sample_strand = get_feature_params_from_metacoord(start_index, partition_df, stranded)
            feature_length = length(feature_metaStart:feature_metaEnd) #find the metaboundaries of the feature the index occurs in
            if feature_length >= sample_window_min #don't bother finding windows on features smaller than min
                window = determine_sample_window(feature_metaStart, feature_metaEnd, start_index, metacoordinate_bitarray, sample_window_min, sample_window_max) #get an appropriate sampling window around the selected index, given the feature boundaries and params
            end
        end
        if window[1] > length(metacoordinate_bitarray) || window[2] > length(metacoordinate_bitarray)
            @error "Error: metacoords $(window[1]), $(window[2]) in partition $partitionid > $(length(metacoordinate_bitarray))"
        end
        sample_scaffoldid, sample_scaffold_start, sample_scaffold_end = meta_to_feature_coord(window[1],window[2],partition_df)
        proposal_sequence = fetch_sequence(sample_scaffoldid, sample_scaffold_start, sample_scaffold_end, genome_reader, sample_strand) #get the sequence associated with the sample window

        if mask_check(proposal_sequence)
            proposal_acceptance = true #if the sequence passes the mask check, accept the proposed sample
            sample_scaffold = sample_scaffoldid
            sample_Start = sample_scaffold_start
            sample_End = sample_scaffold_end
            sample_metaStart = window[1]
            sample_metaEnd = window[2]
            sample_sequence=proposal_sequence
        end
    end
    return sample_scaffold, sample_Start, sample_End, sample_metaStart, sample_metaEnd, sample_sequence
end

#function for a Distributed worker to produce a sample set of given parameters
function get_sample_set(input_sample_jobs::RemoteChannel, completed_sample_jobs::RemoteChannel, progress_updates::RemoteChannel)
    genome_path, genome_index_path, partition_df, partitionid, sample_set_length, sample_window_min, sample_window_max = take!(input_sample_jobs)
    genome_reader = open(BioSequences.FASTA.Reader, genome_path, index=genome_index_path)
    sample_df = DataFrame(SampleScaffold=String[],SampleStart=Int64[],SampleEnd=Int64[],SampleSequence=DNASequence[])
    metacoordinate_bitarray = trues(partition_df.MetaEnd[end])
    sample_set_counter = 0

    while sample_set_counter < sample_set_length #while we don't yet have enough sample sequence
        sample_scaffold::String, sample_Start::Int64, sample_End::Int64, sample_metaStart::Int64, sample_metaEnd::Int64, sample_sequence::DNASequence = get_sample(metacoordinate_bitarray, sample_window_min, sample_window_max,  partition_df, genome_reader, partitionid)
        push!(sample_df,[sample_scaffold, sample_Start, sample_End, sample_sequence]) #push the sample to the df
        sample_length = sample_End - sample_Start + 1
        sample_set_counter += sample_length #increase the counter by the length of the sampled sequence
        metacoordinate_bitarray[sample_metaStart:sample_metaEnd] = [false for base in 1:sample_length] #mark these residues as sampled
        put!(progress_updates, (partitionid, min(sample_set_counter,sample_set_length)))
    end
    close(genome_reader)
    put!(completed_sample_jobs,(partitionid, sample_df))
end

#function to set up Distributed RemoteChannels so partitions can be sampled simultaneously
function setup_sample_jobs(genome_path::String, genome_index_path::String, gff3_path::String, sample_set_length::Int64, sample_window_min::Int64, sample_window_max::Int64, perigenic_pad::Int64)
    coordinate_partitions = partition_genome_coordinates(gff3_path, perigenic_pad)
    sample_sets = DataFrame[]
    input_sample_jobs = RemoteChannel(()->Channel{Tuple}(length(coordinate_partitions))) #channel to hold sampling jobs
    completed_sample_jobs = RemoteChannel(()->Channel{Tuple}(length(coordinate_partitions))) #channel to hold completed sample dfs
    for (partitionid, partition) in coordinate_partitions
        add_metacoordinates!(partition)
        put!(input_sample_jobs, (genome_path, genome_index_path, partition, partitionid, sample_set_length, sample_window_min, sample_window_max))
    end
    return input_sample_jobs, completed_sample_jobs
end

#function to partition a genome into coordinate sets of:
#merged exons
#"periexonic" sequences (genes with 5' and 3' boundaries projected -/+perigenic_pad bp, minus exons) - includes promoter elements, introns, 3' elements
#intergenic sequences (everything else)
#given a valid gff3
function partition_genome_coordinates(gff3_path::String, perigenic_pad::Int64=500)
    # construct dataframes of scaffolds and metacoordinates
    scaffold_df = build_scaffold_df(gff3_path)

    #partition genome into intragenic, periexonic, and exonic coordinate sets
    #assemble exonic featureset
    exon_df = DataFrame(SeqID = String[], Start = Int64[], End = Int64[], Strand=Char[])
    build_feature_df!(gff3_path, "exon", "MT", exon_df)

    #project exon coordinates onto the scaffold bitwise, merging overlapping features and returning the merged dataframe
    merged_exon_df = DataFrame(SeqID = String[], Start = Int64[], End = Int64[], Strand=Char[])
    for scaffold_subframe in DataFrames.groupby(exon_df, :SeqID) # for each scaffold subframe that has exon features
        scaffold_id  = scaffold_subframe.SeqID[1] #get the scaffold id
        scaffold_bitarray = init_scaffold_bitarray(scaffold_id, scaffold_df, false, stranded=true) #init a stranded bitarray of scaffold length
        project_features_to_bitarray!(scaffold_subframe,scaffold_bitarray) #project features as Trues on bitarray of falses
        merged_subframe = get_feature_df_from_bitarray(scaffold_id, scaffold_bitarray) #get a feature df from the projected bitarray
        append!(merged_exon_df,merged_subframe) #append the merged scaffold df to the overall merged df
    end

    #assemble gene featureset
    gene_df =  DataFrame(SeqID = String[], Start = Int64[], End = Int64[], Strand = Char[])
    build_feature_df!(gff3_path, "gene", "MT", gene_df)

    perigenic_pad > 0 && add_pad_to_coordinates!(gene_df, scaffold_df, perigenic_pad) #if a perigenic pad is specified (to capture promoter/downstream elements etc in the periexonic set), apply it to the gene coords

    #build intergenic coordinate set by subtracting gene features from scaffold bitarrays
    intergenic_df = DataFrame(SeqID = String[], Start = Int64[], End = Int64[])
    for scaffold_subframe in DataFrames.groupby(scaffold_df, :SeqID) # for each scaffold subframe that has exon features
        scaffold_id  = scaffold_subframe.SeqID[1] #get the scaffold id
        scaffold_bitarray = init_scaffold_bitarray(scaffold_id, scaffold_df, true) #init a bitarray of scaffold length
        if any(isequal(scaffold_id),gene_df.SeqID) #if any genes on the scafold
            scaffold_genes=gene_df[findall(isequal(scaffold_id), gene_df.SeqID), :] #get the gene rows by finding the scaffold_id
            subtract_features_from_bitarray!(scaffold_genes,scaffold_bitarray) #subtract the gene positions from the scaffold bitarray
        end
        intragenic_subframe = get_feature_df_from_bitarray(scaffold_id, scaffold_bitarray) #get a feature df from the projected bitarray
        append!(intergenic_df,intragenic_subframe) #append the merged scaffold df to the overall merged df
    end

    #build periexonic set by projecting gene coordinates onto the scaffold bitwise, then subtracting the exons
    periexonic_df = DataFrame(SeqID = String[], Start = Int64[], End = Int64[], Strand=Char[])
    for scaffold_subframe in DataFrames.groupby(gene_df, :SeqID) # for each scaffold subframe that has exon features
        scaffold_id  = scaffold_subframe.SeqID[1] #get the scaffold id
        scaffold_bitarray = init_scaffold_bitarray(scaffold_id, scaffold_df, false, stranded=true) #init a bitarray of scaffold length
        project_features_to_bitarray!(scaffold_subframe,scaffold_bitarray) #project features as Trues on bitarray of falses
        if any(isequal(scaffold_id),merged_exon_df.SeqID)
            scaffold_exons=merged_exon_df[findall(isequal(scaffold_id), merged_exon_df.SeqID), :]
            subtract_features_from_bitarray!(scaffold_exons,scaffold_bitarray)
        end
        periexonic_subframe = get_feature_df_from_bitarray(scaffold_id, scaffold_bitarray) #get a feature df from the projected bitarray
        append!(periexonic_df,periexonic_subframe) #append the merged scaffold df to the overall merged df
    end

    return Dict("exon"=>merged_exon_df, "periexonic"=>periexonic_df, "intergenic"=>intergenic_df)
end