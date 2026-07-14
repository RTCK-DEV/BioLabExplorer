import Foundation

public enum SampleDataset {
    public static let proteins: [ProteinSequence] = [
        ProteinSequence(
            id: "soil_bin_0421",
            organism: "synthetic soil metagenome bin",
            source: "bundled synthetic sample",
            annotation: "hypothetical protein",
            sequence: "MTPKIVLAGHGVCPTCGDGVKALAEQGFDVVAVHGHADLPEEVVRQLGADPVVVINGGAGGLGQALAAHLRERGLTVFSGGHDHLYDRLQELARQGATVSVNPQWRDVLAQLAERGVQVPVTVHGGHAGLLDQVREAFGVEVRR",
            knownHitIdentity: 0.18,
            annotationConfidence: 0.12,
            clusterSize: 37
        ),
        ProteinSequence(
            id: "marine_bin_1177",
            organism: "synthetic marine metagenome bin",
            source: "bundled synthetic sample",
            annotation: "conserved membrane protein",
            sequence: "MAHSTNPQVLLAAIVVGLVGLFLAFYLWQRRDSGEPVTEQALRSLGVDKVYQTDGAVVLAALMFFWAFGFLVMSLLGWTLNRERQALVEEGATVSTPQEGLPDPVQLR",
            knownHitIdentity: 0.24,
            annotationConfidence: 0.25,
            clusterSize: 21
        ),
        ProteinSequence(
            id: "thermal_bin_0089",
            organism: "synthetic thermal spring bin",
            source: "bundled synthetic sample",
            annotation: "uncharacterized oxidoreductase-like protein",
            sequence: "MKRVEIVTDTGCGGQAWALAKAGYDVVAVNAGGQGFKGATLNSLAEHGAKVYITCDHAGHGRTFDALKAAEELGVEVLIHHDYNGKPVFEEVVKRFGIPVYIASTPHDLADYAEKLGIPVEEILKA",
            knownHitIdentity: 0.31,
            annotationConfidence: 0.30,
            clusterSize: 54
        ),
        ProteinSequence(
            id: "compost_bin_3012",
            organism: "synthetic compost metagenome bin",
            source: "bundled synthetic sample",
            annotation: "low complexity protein",
            sequence: "MSSSSGSGSGSGSGSGSGSNNNNNNQGQQQQQQQQQQPGGSGSGSQQQGGGPPPQGQGQGQGQGQGSTNTSNNNNHQQQGPGG",
            knownHitIdentity: 0.12,
            annotationConfidence: 0.08,
            clusterSize: 12
        ),
        ProteinSequence(
            id: "freshwater_bin_2205",
            organism: "synthetic freshwater metagenome bin",
            source: "bundled synthetic sample",
            annotation: "DUF-like protein",
            sequence: "MSDPLIKQAVEGAFDSLPVVVTGTSGSGKSTIAKLLAEAGYTVLAGDIDQVNALRRAFEELGFDEVLVVDEPTSALDQLRRELAEHGIPVILVTHDLQQLTEQAVEQGATVYALD",
            knownHitIdentity: 0.43,
            annotationConfidence: 0.52,
            clusterSize: 64
        ),
        ProteinSequence(
            id: "lichen_bin_0144",
            organism: "synthetic lichen-associated bin",
            source: "bundled synthetic sample",
            annotation: "hypothetical protein",
            sequence: "MVNLQELRDKGVKIPVTYCGHCPQGFTAEALERHGIRVVLHHTGDHADAVTQALRDAGVEVIIDRGNPEEAFRRLGRPVAVTGRRAGVDAWLQALAEAGVEVPVKLHTHADLDRA",
            knownHitIdentity: 0.20,
            annotationConfidence: 0.15,
            clusterSize: 43
        ),
        ProteinSequence(
            id: "gut_bin_5520",
            organism: "synthetic gut microbiome bin",
            source: "bundled synthetic sample",
            annotation: "probable aminotransferase fragment",
            sequence: "MSTDFERLREAGITPVVVDATGAVGRTGQALAEAGYRVAVFDTAEELGIPVAVNSAYGQQLDAALVEAGAKVIIEPGEPALKAAVDAGATVTVN",
            knownHitIdentity: 0.62,
            annotationConfidence: 0.82,
            clusterSize: 92
        ),
        ProteinSequence(
            id: "desert_bin_6188",
            organism: "synthetic desert crust bin",
            source: "bundled synthetic sample",
            annotation: "hypothetical protein",
            sequence: "MAEITVDDVLPQGVREWVRKAGIEVKPVDIGGAGGIGLKTAARLAREHGAKTVYATHDDHFTPEQLDALRRQGVEVTLHGDYNDGQVFDGLLAQAGVPVVITRPGGAGGQARQVLES",
            knownHitIdentity: 0.26,
            annotationConfidence: 0.18,
            clusterSize: 18
        )
    ]
}
