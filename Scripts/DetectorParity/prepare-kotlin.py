import shutil
import subprocess
import sys
from pathlib import Path

REVISION = "a52a5cb8e0ab5d228a01a624099f1cd2182f4221"
repository, output, images = map(Path, sys.argv[1:])
source = "app/src/main/java/dev/sawitulm/palmannotate"


def read(path):
    return subprocess.check_output(["git", "-C", repository, "show", f"{REVISION}:{path}"])


def write(directory, name, data):
    path = output / directory / name
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data)


detector = read(f"{source}/data/detection/OnnxDetector.kt")
return_box = b"Bbox.unassigned(\"det$i\", d.x1, d.y1, d.x2, d.y2)"
assert detector.count(return_box) == 1
detector = detector.replace(return_box, return_box + b".also { DetectorProbe.confidences.add(d.score) }")
for message in (
    "Failed to initialize ONNX detector",
    "Failed to load detector config, using defaults",
    "Detection failed",
):
    for priority in ("e", "w"):
        log = f'Log.{priority}(TAG, "{message}", e)'.encode()
        detector = detector.replace(log, f'throw IllegalStateException("{message}", e)'.encode())
write("src/test/kotlin", "OnnxDetector.kt", detector)
for name in ["Bbox.kt", "BunchMeasurements.kt", "AnnotationClass.kt"]:
    write("src/test/kotlin", name, read(f"{source}/domain/model/{name}"))
write(
    "src/test/kotlin", "ComposeColor.kt",
    b"package androidx.compose.ui.graphics\n\ndata class Color(val argb: Long)\n",
)
for name in ["ffb-detector.onnx", "detector.config.json"]:
    write("src/main/assets/models", name, read(f"app/src/main/assets/models/{name}"))
photos = output / "src/main/assets/photos"
photos.mkdir(parents=True, exist_ok=True)
for image in images.iterdir():
    if image.is_file() and image.suffix in {".jpg", ".jpeg", ".png"}:
        shutil.copyfile(image, photos / image.name)
