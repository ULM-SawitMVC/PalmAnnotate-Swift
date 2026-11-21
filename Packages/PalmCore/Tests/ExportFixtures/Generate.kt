package dev.sawitulm.palmannotate.data.storage

import dev.sawitulm.palmannotate.data.export.CaptureSetDescriptor
import dev.sawitulm.palmannotate.data.export.CaptureSetMergePolicy
import dev.sawitulm.palmannotate.data.export.DatasetZipLayout
import dev.sawitulm.palmannotate.data.export.ExportManager
import dev.sawitulm.palmannotate.data.export.FileKind
import dev.sawitulm.palmannotate.data.yolo.YoloParser
import dev.sawitulm.palmannotate.domain.model.*
import dev.sawitulm.palmannotate.domain.results.ResultsComputer
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.time.Instant

// Android-free file adapter for the original manifest and repository producer bodies.
internal class AndroidStorageManager(val rootDir: File) {
    fun imageFile(tree: String, side: Int) = File(rootDir, "images/field/${tree}_${side + 1}.jpg")
    fun depthRawFile(tree: String, side: Int) = File(rootDir, "depth/field/${tree}_${side + 1}.raw")
    fun depthJsonFile(tree: String, side: Int) = File(rootDir, "depth/field/${tree}_${side + 1}.json")
    fun hasValidDepthPair(tree: String, side: Int) =
        depthRawFile(tree, side).isFile && depthJsonFile(tree, side).isFile
    fun depthMetadataHasContentBindings(tree: String, side: Int) = hasValidDepthPair(tree, side)
    fun videoFile(tree: String) = File(rootDir, "video/$tree.mp4")
    fun writeText(file: File, text: String) {
        file.parentFile.mkdirs()
        file.writeText(text)
    }
}

private const val capture = "2023-11-15T10:00:00.000Z"
private const val save = "2023-11-15T10:01:00.000Z"
private val captureMs = Instant.parse(capture).toEpochMilli()
private val saveMs = Instant.parse(save).toEpochMilli()
private const val install = "synthetic-palm-export-install"
private const val captureSet = "e260f7cb-b4d7-42ad-abe6-5d0ec6bdde57"
private const val variety = "DAMIMAS"

fun main(args: Array<String>) {
    val fixtures = File(args[0])
    val temp = File(args[1])
    val cases = JSONArray(File(fixtures, "cases.json").readText())
    val token = CaptureSetPolicy.deviceTokenFrom(install)
    for (index in 0 until cases.length()) {
        val spec = cases.getJSONObject(index)
        val name = spec.getString("name")
        val type = DatasetType.valueOf(spec.getString("type"))
        val sideCount = spec.getInt("sideCount")
        val block = "QA${index + 1}"
        val split = if (type.requiresVideo) "test" else "field"
        val identity = CaptureSetIdentity(captureSet, token, if (spec.optBoolean("tokenized")) token else "")
        val tree = CaptureSetPolicy.treeName(variety, block, identity.nameToken, 1, type)
        val storage = AndroidStorageManager(File(temp, name))
        val repository = RepositoryProjections(storage)
        val boxes = spec.getJSONArray("boxes")
        val sides = (0 until sideCount).map { side ->
            val image = storage.imageFile(tree, side)
            image.parentFile.mkdirs()
            image.writeBytes(byteArrayOf(0xff.toByte(), 0xd8.toByte(), side.toByte(), 0xff.toByte(), 0xd9.toByte()))
            val final = (0 until boxes.length()).map { boxes.getJSONObject(it) }
                .filter { it.getInt("side") == side }
                .map {
                    val rect = it.getJSONArray("rect")
                    val cls = AnnotationClass.fromId(it.getInt("classId"))
                    Bbox(it.getString("id"), cls.id, cls.displayName,
                        rect.getDouble(0).toFloat(), rect.getDouble(1).toFloat(),
                        rect.getDouble(2).toFloat(), rect.getDouble(3).toFloat(),
                        BunchMeasurements(
                            it.optDouble("weight").takeIf(Double::isFinite),
                            it.optDouble("height").takeIf(Double::isFinite),
                            it.optDouble("circumference").takeIf(Double::isFinite),
                            it.optString("notes").takeIf { note -> it.has("notes") && note.isNotEmpty() },
                        ),
                    )
                }
            val suggested = final.filter { it.id.startsWith("det") }.map {
                it.copy(classId = -1, className = "U", measurements = BunchMeasurements())
            }
            TreeSide(side, "Side ${side + 1}", null, null, 1024, 1024, final, suggested,
                DepthArtifactContract.sha256Hex(image), CaptureOrigin.PHONE_CAMERA)
        }
        if (type.requiresVideo) {
            val file = storage.videoFile(tree)
            file.parentFile.mkdirs()
            file.writeBytes(byteArrayOf(0, 0, 0, 8, 102, 114, 101, 101))
        }
        val gps = when (name) {
            "multiside-4" -> GpsFreshnessPolicy.forFix(-3.3, 114.6, 3.1f, captureMs - 61_000,
                "gps", GpsSource.CURRENT_FIX, captureMs)
            "video-8" -> GpsProvenance.unavailable(GpsStatus.PERMISSION_DENIED)
            else -> GpsProvenance.unavailable(GpsStatus.UNAVAILABLE)
        }
        val links = spec.getJSONArray("links")
        val session = ActiveSession("fixture", tree, split, sides, emptyList(),
            (0 until links.length()).map {
                val link = links.getJSONArray(it)
                CrossSideLink.create("L$it", link.getInt(0), link.getString(1), link.getInt(2), link.getString(3))
            },
            TreeMetadata(variety, block, "1", "2023-11-15", captureMs, gps,
                if (name == "multiside-4") "  Operator A  " else "", identity),
            datasetType = type,
        )
        val results = ResultsComputer.compute(session)
        val output = ExportManager.generateOutputJson(session, results)
        output.getJSONObject("metadata").put("generated_at", save)
        val metadataText = repository.metadata(session, captureMs)
        val outputText = output.toString(2)
        storage.writeText(File(storage.rootDir, "Output JSON/$tree.json"), outputText)
        storage.writeText(File(storage.rootDir, "metadata/$tree.json"), metadataText)
        val labels = sides.map { side ->
            YoloParser.serialize(side.bboxes, side.imageWidth, side.imageHeight,
                if (type == DatasetType.BUNCH_WEIGHT) 0 else null).also {
                check(it == ExportManager.generateYoloTxt(side, type))
                storage.writeText(File(storage.rootDir, "labels/field/${tree}_${side.sideIndex + 1}.txt"), it)
            }
        }
        val manifest = TreePackageManifest.materialize(storage, tree, sides, identity)
        val descriptor = CaptureSetDescriptor.build(
            identity, "test", "2023-11-15T10:01:00Z",
            listOf(CaptureSetMergePolicy.Entry(tree, captureSet, token,
                DepthArtifactContract.sha256Hex(manifest.toByteArray())))
        )
        val paths = DatasetZipLayout.zipEntriesFor(tree, sideCount).filter {
            it.kind !in setOf(FileKind.DEPTH_RAW, FileKind.DEPTH_JSON) &&
                (it.kind != FileKind.VIDEO || type.requiresVideo)
        }.map { it.zipPath } + CaptureSetDescriptor.FILE_NAME

        File(fixtures, "$name.json").writeText(JSONObject().apply {
            put("tree", tree)
            put("output", output)
            put("metadata", JSONObject(metadataText))
            put("manifest", JSONObject(manifest))
            put("descriptor", descriptor)
            put("csv", ExportManager.generateCsv(session, results))
            put("identity", ExportManager.generateIdentityJson(session, results))
            put("labels", JSONArray(labels))
            put("logs", JSONArray(sides.map { repository.log(session, it, saveMs) }))
            put("paths", JSONArray(paths.sorted()))
            // Preserve the exact Kotlin bytes used by its two JSON digests and descriptor.
            put("outputText", outputText)
            put("metadataText", metadataText)
            put("manifestText", manifest)
        }.toString(2) + "\n")
    }
}
