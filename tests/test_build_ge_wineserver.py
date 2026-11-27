"""tools/build_ge_wineserver.sh : la vérification du protocole et la copie de Proton, sans rien télécharger ni compiler
(le script est chargé avec `source`, qui ne définit que ses fonctions ; un faux objdump remplace le vrai)."""
import os
import shutil
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "tools" / "build_ge_wineserver.sh"

pytestmark = pytest.mark.skipif(os.name == "nt" or shutil.which("bash") is None, reason="script bash, Linux")


def run(tmp_path, body, objdump_out=""):
    """Lance `body` après `source` du script, avec un faux objdump qui affiche `objdump_out`."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(exist_ok=True)
    fake = bin_dir / "objdump"
    fake.write_text(f"#!/bin/sh\ncat <<'END'\n{objdump_out}\nEND\n")
    fake.chmod(0o755)
    env = dict(os.environ, PATH=f"{bin_dir}{os.pathsep}{os.environ['PATH']}")
    return subprocess.run(["bash", "-c", f'set -euo pipefail; source "{SCRIPT}"; {body}'],
                          capture_output=True, text=True, env=env, cwd=tmp_path, check=False)


def fake_proton(root):
    (root / "files" / "bin").mkdir(parents=True)
    (root / "files" / "lib" / "wine" / "x86_64-unix").mkdir(parents=True)
    (root / "files" / "bin" / "wineserver").write_text("stock")
    (root / "files" / "bin" / "wine").write_text("wine")
    (root / "files" / "lib" / "wine" / "x86_64-unix" / "ntdll.so").write_text("ntdll")
    (root / "proton").write_text("launcher")
    return root


def test_le_protocole_de_ntdll_doit_etre_celui_du_wineserver(tmp_path):
    inst = fake_proton(tmp_path / "GE-Proton")
    ok = run(tmp_path, f'check_protocol "{inst}" 938', "  1234:\tcmp    $0x3aa,%eax")
    assert ok.returncode == 0, ok.stderr
    assert "protocol 938 matches" in ok.stdout
    wrong = run(tmp_path, f'check_protocol "{inst}" 938', "  1234:\tcmp    $0x3a9,%eax")
    assert wrong.returncode != 0
    assert "wrong source for this Proton" in wrong.stderr


def test_la_copie_ne_remplace_que_le_wineserver(tmp_path):
    inst = fake_proton(tmp_path / "GE-Proton")
    server = tmp_path / "wineserver"
    server.write_text("view tree")
    out = tmp_path / "GE-Proton-viewtree"
    done = run(tmp_path, f'copy_proton "{inst}" "{server}" "{out}"')
    assert done.returncode == 0, done.stderr
    assert (out / "files" / "bin" / "wineserver").read_text() == "view tree"
    assert (inst / "files" / "bin" / "wineserver").read_text() == "stock"
    for rel in ["proton", "files/bin/wine", "files/lib/wine/x86_64-unix/ntdll.so"]:
        assert (out / rel).read_text() == (inst / rel).read_text()
    again = run(tmp_path, f'copy_proton "{inst}" "{server}" "{out}"')
    assert again.returncode != 0 and "exists" in again.stderr


def test_seules_les_versions_epinglees_sont_construites(tmp_path):
    known = run(tmp_path, "ge_commit GE-Proton11-14")
    assert known.returncode == 0 and len(known.stdout.strip()) == 40
    assert run(tmp_path, "ge_commit GE-Proton99-1").returncode != 0
    unknown = run(tmp_path, f'main GE-Proton99-1 "{tmp_path}" "{tmp_path / "work"}"')
    assert unknown.returncode != 0 and "no pinned commit" in unknown.stderr
    assert not (tmp_path / "work").exists()
