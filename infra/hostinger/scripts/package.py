#!/usr/bin/env python3
"""Package only the exact application inputs hashed by the Terraform plan."""

import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import tarfile
import tempfile


def package(source_root, manifest, output):
    root = Path(source_root).resolve(strict=True)
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix="source-", dir=output.parent)
    try:
        with os.fdopen(fd, "wb") as raw:
            with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
                with tarfile.open(fileobj=compressed, mode="w") as archive:
                    for name, expected_hash in sorted(manifest.items()):
                        relative = PurePosixPath(name)
                        if relative.is_absolute() or ".." in relative.parts:
                            raise ValueError(f"Unsafe source path: {name}")
                        path = root.joinpath(*relative.parts)
                        if any(root.joinpath(*relative.parts[:i]).is_symlink() for i in range(1, len(relative.parts) + 1)):
                            raise ValueError(f"Symlink source inputs are not supported: {name}")
                        contents = path.read_bytes()
                        if hashlib.sha256(contents).hexdigest() != expected_hash:
                            raise ValueError(f"Source changed since planning: {name}. Run terraform plan again.")
                        entry = tarfile.TarInfo(name)
                        entry.size = len(contents)
                        entry.mode = 0o644
                        entry.mtime = 0
                        archive.addfile(entry, io.BytesIO(contents))
        os.chmod(temporary, 0o600)
        os.replace(temporary, output)
    except BaseException:
        Path(temporary).unlink(missing_ok=True)
        raise
    print(f"Packaged {len(manifest)} application files.")


if __name__ == "__main__":
    package(os.environ["SOURCE_ROOT"], json.loads(os.environ["SOURCE_MANIFEST_JSON"]), os.environ["OUTPUT_FILE"])
