/*
 * Copyright (c) 2013, Centre for Genomic Regulation (CRG) and the authors.
 *
 *   This file is part of 'Piper-NF'.
 *
 *   Piper-NF is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published by
 *   the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   Piper-NF is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   along with Piper-NF.  If not, see <http://www.gnu.org/licenses/>.
 */


import groovyx.gpars.dataflow.operator.DataflowEventAdapter
import groovyx.gpars.dataflow.operator.DataflowProcessor
import com.google.common.collect.Multiset
import com.google.common.collect.HashMultiset
import nextflow.util.CacheHelper


/* 
 * Main Piper-NF pipeline script
 *
 * @authors
 * Giovanni Bussotti <giovannibussotti@gmail.com>
 * Paolo Di Tommaso <paolo.ditommaso@gmail.com>
 * Pablo Prieto <poena.funesta@gmail.com> 
 *
 *
 * Defines the pipeline parameters.
 * The values in the 'params' map can be overridden on the command line by specifying a
 * option prefixed with a double '-' char, for example
 *
 * $ nextflow piper.nf --query=<path to your file name>
 *
 */

params.queryChunkSize = 100
params.query = 'tutorial/5_RNA_queries.fa'
params.genomesDb = 'db'
params.resultDir = 'result'
params.blastStrategy = 'ncbi-blast'     // the blast tool to be used, choose between: ncbi-blast, wu-blast
params.alignStrategy = 'slow_pair'      // defines the T-Coffee alignment method
params.exonerateSuccess = '1'
params.exonerateMode = 'exhaustive'
params.exonerateChunkSize = 200


// these parameters are mutually exclusive
// Input genome can be specified by
// - genomes-file: a file containing the list of genomes FASTA to be processed
// - genomes-list: a comma separated list of genomes FASTA file
// - genomes-folder: a directory containing a folder for each genome FASTA file
params['genomes-file'] = null
params['genomes-list'] = null
params['genomes-folder'] = "tutorial/genomes/"

queryFile = file(params.query)
dbPath = file(params.genomesDb)

if( !dbPath.exists() ) {
    log.warn "Creating genomes-db path: $dbPath"
    if( !dbPath.mkdirs() ) {
        exit 1, "Cannot create genomes-db path: $dbPath -- check file system permissions"
    }
}

log.info "P I P E R - RNA mapping pipeline - ver 1.1"
log.info "=========================================="
log.info "query               : ${queryFile}"
log.info "genomes-db          : ${dbPath}"
log.info "query-chunk-size    : ${params.queryChunkSize}"
log.info "result-dir          : ${params.resultDir}"
log.info "blast-strategy      : ${params.blastStrategy}"
log.info "align-strategy      : ${params.alignStrategy}"
log.info "exonerate-success:  : ${params.exonerateSuccess}"
log.info "exonerate-mode:     : ${params.exonerateMode}"
log.info "exonerate-chunk-size: ${params.exonerateChunkSize}"
log.info "pool-size           : ${config.poolSize}"
log.info "\n"

/*
 * Find out all the genomes files in the specified directory.
 *
 * More in detail teh 'sourceGenomesPath' points to a directory having a
 * sub-folder for each genome it is required to process.
 *
 * Each sub-folder must contain the genome FASTA file to be processed.
 *
 * The sub-folder name is used to identify the genome in the computation.
 *
 * All the genomes names found in this path are put in a list named 'formatName',
 * which control the pipeline execution.
 *
 */

allGenomes = [:]

// when the provided source path is a FILE
// each line represent the path to a genome file
if( params['genomes-file'] ) {
    def genomesFile = file(params['genomes-file'])
    if( genomesFile.isEmpty() ) {
        exit 1, "Not a valid input genomes descriptor file: ${genomesFile}"
    }

    allGenomes = parseGenomesFile(dbPath, genomesFile, params.blastStrategy)
}

else if( params['genomes-list'] ) {
   allGenomes = parseGenomesList(dbPath, params['genomes-list'], params.blastStrategy)
}

else if( params['genomes-folder'] ) {
    def sourcePath = file(params['genomes-folder'])
    if( !sourcePath.exists() || sourcePath.isEmpty() ) {
        exit 4, "Not a valid input genomes folder: ${sourcePath}"
    }

    allGenomes = parseGenomesFolder(dbPath, sourcePath, params.blastStrategy)
}

else {
    exit 5, "No input genome(s) provided -- Use one of the following CLI options 'genomes-file' or 'genomes-list' or 'genomes-folder' "
}

if( !allGenomes ) {
    exit 6, "No genomes found in path"
}

allGenomes.each { name, entry ->
    log.info "Validating genome: $name -- file: ${entry.genome_fa}"
    if( !entry.genome_fa.exists() ) {
        exit 3, "Missing genome file: ${entry.genome_fa}"
    }
}

// get all genomes ID found and put into a list
formatName = allGenomes.keySet()


/*
 * Split the query input file in many small files (chunks).
 *
 * The number of sequences in each chunk is controlled by the parameter 'queryChunkSize'
 * The chunk files are saved in a local folder define by the variable 'querySplits'
 *
 */

// create a folder that may be cached, using the 'queryFile' and the number chunks as cache key
querySplits = cacheableDir([queryFile, params.queryChunkSize])
log.debug "Folder querySplits: ${querySplits}"

if( querySplits.isEmpty() ) {
    log.info "Splitting query file: $queryFile .."
    chunkCount=0
    queryFile.chunkFasta( params.queryChunkSize ) { sequence ->
        def file = new File(querySplits, "seq_${chunkCount++}")
        file.text = sequence
    }
    log.info "Created $chunkCount input chunks to path: ${querySplits}"
}
else {
    log.info "Cached query splits > ${querySplits.list().size()} input query chunks"
}


// use a set since there should be not repetition
allQueryIDs = new HashSet()
// the folder where store the all the query sequences as files
File queryEntries = cacheableDir(queryFile)
log.debug "Folder queryEntries: ${queryEntries}"

queryFile.chunkFasta() { String chunk ->
    // get sequence 'queryId'
    String queryId = chunk.readLines()[0].replaceAll( /^>(\S*).*$/, '$1' )
    // add the 'queryId' to the list
    allQueryIDs << queryId
    // store the chunk to a file named as the 'queryId'
    def fileEntry = new File(queryEntries, queryId)
    if( fileEntry.isEmpty() ) {
        fileEntry.text = chunk
    }
}


/*
 * Create the required databases (BLAST,CHR) if they does not exists.
 *
 * This task is executed for each genome in the list 'formatName'
 * The tasks 'sends' out the name of the genome to be processed
 * by the next step in the pipeline using the variable 'blastName'
 */


def sed_cmd = (System.properties['os.name'] == 'Mac OS X' ? 'gsed' : 'sed')
def split_cmd = (System.properties['os.name'] == 'Mac OS X' ? 'gcsplit' : 'csplit')

task('format') {
    input formatName
    output blastName
    
    """
    set -e
    NAME=${formatName}
    FASTA=${allGenomes[formatName].genome_fa}
    CHR_DB=${allGenomes[formatName].chr_db}
    BLAST_DB=${allGenomes[formatName].blast_db}

    ## Create the BLAST db if they does not exist
    if [[ ! `ls -A ${BLAST_DB} 2>/dev/null` ]]; then

        ## Create the target folder
        mkdir -p ${BLAST_DB}

        ## Format the BLAST DB
        x-format.sh ${params.blastStrategy} ${FASTA} ${BLAST_DB}
    fi


    ## Create the CHR database if does not exist
    if [[ ! `ls -A ${CHR_DB} 2>/dev/null` ]]; then

        ## split the fasta in a file for each sequence 'seq_*'
        ${split_cmd} ${FASTA} '%^>%' '/^>/' '{*}' -f seq_ -n 5

        ## create the target folder
        mkdir -p ${CHR_DB}

        ## rename and move to the target folder
        for x in seq_*; do
        SEQID=`grep -E "^>" $x | ${sed_cmd} -r 's/^>(\\S*).*/\\1/' | ${sed_cmd} 's/[\\>\\<\\/\\''\\:\\\\]/_/'`
        mv $x ${CHR_DB}/$SEQID;
        done

    fi

    echo $NAME > blastName

    """
}



/*
 * Iterate over the query chunks and create a pair (genome name, chunk file) for each of them
 */
blastId = channel()
blastQuery = channel()

blastName.each {

    def name = it.text.trim()
    querySplits.eachFile { chunk ->
        log.info "Blasting > $name - chunk: $chunk"
        synchronized(this) {
            blastId << name
            blastQuery << chunk.absoluteFile
        }
    }

}


/*
 * Implements the BLAST step
 */

task ('blast') {
    input blastId
    input blastQuery
    output exonerateId
    output exonerateQuery
    output blastResult
    
    """
    set -e
    echo ${blastId} > exonerateId
    x-blast.sh '${params.blastStrategy}' ${allGenomes[blastId].blast_db} ${blastQuery} > blastResult
    ln -s ${blastQuery} exonerateQuery
    """

}

/*
 * == Blast post-process
 *
 * Split blastResult to small chunks chunks containing at most 'exonerateChunkSize' lines,
 * this chunks feed the exonerate step
 */

exonerate_in = channel()
operator( inputs: [exonerateId, exonerateQuery, blastResult], outputs: [exonerate_in] ) { specieId, fileQuery, fileBlast ->

    fileBlast.chunkLines( size: params.exonerateChunkSize, autoClose: false  ) { lines ->
        // create the chunk file
        def fileChunk = cacheableFile( lines, 'chunk' )
        if( !fileChunk.exists() ) {
            fileChunk.text = lines
        }

        // create 3-tuple to feed to 'exonerate' step
        def id = specieId.text.trim()
        exonerate_in << [ specie: id, query: fileQuery, chunk: fileChunk, chr_db: allGenomes[id].chr_db ]
    }

}


/*
 * Collect the BLAST output chunks and apply the 'exonerate' function
 */

exonerateOut = channel()
exonerateGtf = channel()

task ('exonerate') {
    input exonerate_in
    output '*.fa': exonerateOut
    output '*.gtf': exonerateGtf
    
    """
    specie='${exonerate_in.specie}'
    chr=${exonerate_in.chr_db}
    ## apply exonerate
    exonerateRemapping.pl -query ${exonerate_in.query} -mf2 ${exonerate_in.chunk} -targetGenomeFolder \$chr -exonerate_lines_mode ${params.exonerateMode} -exonerate_success_mode ${params.exonerateMode} -ner no

    mv chunk.fa \${specie}.fa
    mv chunk.ex.gtf \${specie}.ex.gtf
    """
}

/*
 * post-process 'exonerate' result
 */

normalizedFasta = channel()
normalizedGtf = channel()
normalizationDone = val()
dir = tempDir()
log.debug "Folder exonerateHits: ${dir}"


def foo() {
    normalizationDone << 1
}


def listener = new DataflowEventAdapter() {
    @Override
    public void afterStop(final DataflowProcessor processor) {
        foo()
    }
}

Multiset hitSet = HashMultiset.create()

operator( inputs:[exonerateOut, exonerateGtf], outputs: [normalizedFasta, normalizedGtf], maxForks: 1, listeners: [listener] ) { fasta, gtf ->

    def specie = fasta.baseName
    def replace = []

    fasta.chunkFasta(autoClose:false) { seq ->
 
        // parse the sequence id
        def seqId = seq.readLines()[0]
        def matcher = (seqId =~ />(.*)_(hit\d*)(.*)/ )
        def (queryId, hitName, extra) = matcher[0][1..3]
        def sequence = seq.readLines()[1..-1].join('\n')

        // create a multi-fasta file for each 'queryId'
        if( !allQueryIDs.contains(queryId) ) {
            println "Skipping queryId: $queryId -- since it's not contained in the source query"
        }

        log.debug "Processing queryId: ${queryId}"
        def file = new File(dir, "${queryId}.mfa")

        if( !file.exists() ) {
            // the very fist time prepend the sequence in the query file
            file << new File(queryEntries, queryId).text
            // note: the file is bound over the channel here, to be sure
            // to send it out just one time
            normalizedFasta << file
        }

        // update the hit name
        def key = [specie, queryId]
        def count = hitSet.add(key, 1) +1
        def newHit = "hit$count"
        if( hitName != newHit ) {
            log.debug "Replacing hitName: $hitName with: $newHit using key: $key"
            replace << [queryId: queryId, oldHit: hitName, newHit: newHit ]
            hitName = newHit
        }

        // now append the query content
        file << ">${queryId}_${hitName}${extra}_${specie}\n"
        file << sequence
        file << '\n'

    }

    // normalizing hitNames
    if( replace ) {
        def str = gtf.text
        replace?.each {
            log.debug "Replacing hitName: $it in GTF file: $gtf"
            def pattern = "hitName \"${it.queryId}_${it.oldHit}\";"
            str = str.replaceAll( ~/$pattern/, "hitName \"${it.queryId}_${it.newHit}\";" )
        }

        def newGtf = cacheableFile( gtf )
        newGtf.text = str
        log.debug "Updated GTF file: $newGtf"

        gtf = newGtf
    }

    // send out the 'gtf' file
    normalizedGtf << gtf
}


alignment = channel()

task('align') {
    input normalizationDone
    input normalizedFasta
    output '*.aln': alignment

    """
    t_coffee -method ${params.alignStrategy} -in ${normalizedFasta} -n_core 1
    """
}


similarity = channel()

merge('similarity') {
    input alignment
    output '*': similarity

    """
    baseName="$alignment.baseName"
    t_coffee -other_pg seq_reformat -in $alignment -output sim > \$baseName
    """
}

/*
 * Copy the GFT files produces by the Exonerate steps into the result (current) folder
 */

resultDir = file(params.resultDir)
resultDir.with {
    if( isNotEmpty() ) { deleteDir() }
    mkdirs()
}


normalizedGtf.each { sourceFile ->
    if( sourceFile.size() == 0 ) return

    def name = sourceFile.name
    def targetFile = new File(resultDir, name)
    targetFile << sourceFile.text
}

simFolder = val()
similarity.whenBound { file -> if(file instanceof File) simFolder << file.parent }

/*
 * Compute the similarity Matrix
 */
task ('matrix') {
    echo true
    input simFolder
    output simMatrix

    """
    echo '\n====== Pipe-R sim matrix ======='
    sim2matrix.pl -query $queryFile -data_dir $simFolder -genomes_dir $dbPath | tee simMatrix
    echo '\n'
    """
}

simMatrixFile = simMatrix.val
simMatrixFile.copyTo( new File(resultDir,'simMatrix.csv') )


// ----==== utility methods ====----


def parseGenomesFile(File dbPath, File sourcePath, String blastStrategy) {

    def absPath = dbPath.absoluteFile
    def result = [:]

    // parse the genomes input file files (genome-id, path to genome file)
    int count=0
    sourcePath.eachLine { line ->

        def genomeId
        def path

        def items = line.trim().split(/\s+/)
        if( items.size() > 1 ) {
            count++
            (path, genomeId) = items
        }
        else if( items.size() ==1 && items[0] ){
            count++
            genomeId = "gen${count}"
            path = items[0]
        }
        else {
            return
        }

        result[ genomeId ] = [
                genome_fa: new File(path).absoluteFile,
                chr_db: new File(absPath,"${genomeId}/chr"),
                blast_db: new File(absPath, "${genomeId}/${blastStrategy}-db")
            ]
    }

    result
}



def parseGenomesList(File dbPath, String genomesList, String blastStrategy) {

    def count=0
    def files = genomesList.split(',').collect { new File(it.trim()).absoluteFile }
    def result = [:]
    def absPath = dbPath.absoluteFile

    files.each { genomeFile ->

        def genomeId = "gen${++count}"
        result[ genomeId ] = [
                genome_fa: genomeFile,
                chr_db: new File(absPath,"${genomeId}/chr"),
                blast_db: new File(absPath, "${genomeId}/${blastStrategy}-db")
            ]

    }
    result
}

def parseGenomesFolder(File dbPath, File sourcePath, String blastStrategy) {

    def result = [:]
    def absPath = dbPath.absoluteFile

    sourcePath.absoluteFile.eachDir { File path ->
        def fasta = path.listFiles().find { File file -> file.name.endsWith('.fa') }
        if( fasta ) {
            result[ path.name ] = [
                    genome_fa: fasta,
                    chr_db: new File(absPath,"${path.name}/chr"),
                    blast_db: new File(absPath, "${path.name}/${blastStrategy}-db")
                ]
        }
    }
    result
}

// ----===== TEST ====-------

def void testParseGenomesFile() {

    def db = new File('db')
    def source = new File('test-source')
    try {
        source.text =
            '''
            x/file1.fa
            y/file2.fa   genx
            z/file3.fa
            '''

        def result = parseGenomesFile(db, source, 'wu-blast')

        assert result.size() == 3

        assert result['gen1'].genome_fa == new File('x/file1.fa').absoluteFile
        assert result['genx'].genome_fa == new File('y/file2.fa').absoluteFile
        assert result['gen3'].genome_fa == new File('z/file3.fa').absoluteFile

        assert result['gen1'].chr_db == new File(db, 'gen1/chr').absoluteFile
        assert result['genx'].chr_db == new File(db, 'genx/chr').absoluteFile
        assert result['gen3'].chr_db == new File(db, 'gen3/chr').absoluteFile

        assert result['gen1'].blast_db == new File(db, 'gen1/wu-blast-db').absoluteFile
        assert result['genx'].blast_db == new File(db, 'genx/wu-blast-db').absoluteFile
        assert result['gen3'].blast_db == new File(db, 'gen3/wu-blast-db').absoluteFile

    }
    finally {
        source.delete()
    }
}



def void testParseGenomesList() {

      def db = new File('db')

      // call the function to test
      def result = parseGenomesList(db, 'alpha.fa, beta.fa, delta.fa', 'x-blast')

      // verify result
      assert result.size() == 3

      assert result['gen1'].genome_fa == new File('alpha.fa').absoluteFile
      assert result['gen2'].genome_fa == new File('beta.fa').absoluteFile
      assert result['gen3'].genome_fa == new File('delta.fa').absoluteFile

      assert result['gen1'].chr_db == new File(db, 'gen1/chr') .absoluteFile
      assert result['gen2'].chr_db == new File(db, 'gen2/chr') .absoluteFile
      assert result['gen3'].chr_db == new File(db, 'gen3/chr') .absoluteFile

      assert result['gen1'].blast_db == new File(db, 'gen1/x-blast-db') .absoluteFile
      assert result['gen2'].blast_db == new File(db, 'gen2/x-blast-db') .absoluteFile
      assert result['gen3'].blast_db == new File(db, 'gen3/x-blast-db') .absoluteFile

}

def void testParseGenomesFolder() {

  def root = new File('test-folder')

  try {
      // create the structure to test
      def folder1 = new File(root, 'alpha')
      def folder2 = new File(root, 'beta')
      def folder3 = new File(root, 'delta')
      folder1.mkdirs()
      folder2.mkdirs()
      folder3.mkdirs()

      new File(folder1, 'gen1.fa').text = 'uno'
      new File(folder2, 'gen2.fa').text = 'due'
      new File(folder3, 'gen3.fa').text = 'tre'

      def db = new File('db')

      // call the function to test
      def result = parseGenomesFolder(db, root, 'y-blast')

      // verify result
      assert result.size() == 3

      assert result['alpha'].genome_fa == new File(folder1, 'gen1.fa').absoluteFile
      assert result['beta'].genome_fa == new File(folder2, 'gen2.fa').absoluteFile
      assert result['delta'].genome_fa == new File(folder3, 'gen3.fa').absoluteFile

      assert result['alpha'].chr_db == new File(db, 'alpha/chr') .absoluteFile
      assert result['beta'].chr_db == new File(db, 'beta/chr') .absoluteFile
      assert result['delta'].chr_db == new File(db, 'delta/chr') .absoluteFile

      assert result['alpha'].blast_db == new File(db, 'alpha/y-blast-db') .absoluteFile
      assert result['beta'].blast_db == new File(db, 'beta/y-blast-db') .absoluteFile
      assert result['delta'].blast_db == new File(db, 'delta/y-blast-db') .absoluteFile

  }
  finally {
     root.deleteDir()
  }


}