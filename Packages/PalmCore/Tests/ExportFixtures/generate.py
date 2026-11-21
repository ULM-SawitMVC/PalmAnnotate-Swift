#!/usr/bin/env python3
"""Build Kotlin export goldens from the exact Android revision using kotlinc and JDK 17."""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import urllib.request

revision = "5d671c30c1c17f3c7b1a40db367b74a295c82cf5"
fixtures = Path(__file__).resolve().parent
source = Path(sys.argv[1]).resolve()
if subprocess.check_output(["git", "-C", source, "rev-parse", "HEAD"], text=True).strip() != revision:
    raise SystemExit(f"Expected checkout at {revision}")

paths = [
    "domain/model/ActiveSession.kt",
    "domain/model/AnnotationClass.kt",
    "domain/model/Bbox.kt",
    "domain/model/BunchMeasurements.kt",
    "domain/model/CaptureSetIdentity.kt",
    "domain/model/CrossSideLink.kt",
    "domain/model/DatasetType.kt",
    "domain/model/GpsProvenance.kt",
    "domain/model/TreeSide.kt",
    "domain/model/Results.kt",
    "domain/dedup/UnionFind.kt",
    "domain/results/ResultsComputer.kt",
    "data/export/ExportManager.kt",
    "data/export/CaptureSetDescriptor.kt",
    "data/storage/ArtifactIdentityPolicy.kt",
    "data/storage/CaptureIntegrityPolicy.kt",
    "data/storage/DepthArtifactContract.kt",
    "data/storage/PackageProvenanceCodec.kt",
    "data/storage/TreePackageManifest.kt",
    "data/yolo/YoloParser.kt",
]

def read_source(path):
    return subprocess.check_output([
        "git", "-C", source, "show",
        f"{revision}:app/src/main/java/dev/sawitulm/palmannotate/{path}",
    ], text=True)

with tempfile.TemporaryDirectory(prefix="palm-kotlin-goldens-") as temp:
    build = Path(temp)
    for path in paths:
        (build / Path(path).name).write_text(read_source(path))
    repo = read_source("data/storage/SessionRepository.kt")
    metadata = repo[repo.index("    private fun buildMetadataJson("):repo.index("    // ─── Load / save one tree")]
    logs = repo[repo.index("    private fun buildAnnotLog("):repo.index("// ─── Mappers + summary types")]
    # Compile the actual private producer bodies with the dependencies they use.
    # Freeze the independent wall clock after running the annotation-log producer.
    (build / "RepositoryProjections.kt").write_text("""
package dev.sawitulm.palmannotate.data.storage

import dev.sawitulm.palmannotate.domain.model.*
import org.json.JSONArray
import org.json.JSONObject
import java.text.SimpleDateFormat
import java.util.*

internal data class SessionEntity(val variety: String, val block: String)

internal class RepositoryProjections(private val storage: AndroidStorageManager) {
    private val ISO_FORMAT = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSS'Z'", Locale.US).apply {
        timeZone = TimeZone.getTimeZone("UTC")
    }
    fun metadata(session: ActiveSession, at: Long): String {
        val meta = requireNotNull(session.metadata)
        return buildMetadataJson(
            meta, session.treeName, SessionEntity(meta.variety, meta.block), meta.treeId.toInt(),
            session.sides, meta.identity, meta.gps, meta.operatorName, meta.date, at,
            if (session.datasetType.requiresVideo) videoArtifactJson(session.treeName) else null
        ).toString(2)
    }
    fun log(session: ActiveSession, side: TreeSide, at: Long): JSONObject =
        JSONObject(buildAnnotLog(session.treeName, session.split, side, session.datasetType)).put("savedAt", at)
""" + metadata + logs)
    zip_source = read_source("data/export/DatasetZipExporter.kt")
    (build / "ZipLayout.kt").write_text(
        "package dev.sawitulm.palmannotate.data.export\n" + zip_source[zip_source.index("internal enum class FileKind"):]
    )
    (build / "Uri.kt").write_text("package android.net\nclass Uri\n")
    (build / "Color.kt").write_text("package androidx.compose.ui.graphics\nclass Color(val value: Long)\n")
    jar = build / "json.jar"
    urllib.request.urlretrieve(
        "https://repo.maven.apache.org/maven2/org/json/json/20240303/json-20240303.jar", jar
    )
    java_home = os.environ.get("JAVA_HOME")
    java = Path(java_home) / "bin/java" if java_home else "java"
    subprocess.run([
        "kotlinc", *sorted(build.glob("*.kt")), fixtures / "Generate.kt",
        "-classpath", jar, "-include-runtime", "-d", build / "fixtures.jar",
    ], check=True)
    subprocess.run([
        java, "-cp", f"{build / 'fixtures.jar'}:{jar}",
        "dev.sawitulm.palmannotate.data.storage.GenerateKt", fixtures, build,
    ], check=True)
