#!/usr/bin/env python3
import re
import site
import subprocess
import sys
from pathlib import Path


def run(command):
    subprocess.run(command, check=True)


def ensure_ruamel():
    try:
        from ruamel.yaml import YAML
    except ImportError:
        run([sys.executable, "-m", "pip", "install", "ruamel.yaml"])
        try:
            from ruamel.yaml import YAML
        except ImportError:
            run([sys.executable, "-m", "pip", "install", "--user", "ruamel.yaml"])
            site.addsitedir(site.getusersitepackages())
            from ruamel.yaml import YAML
    return YAML


def patch_build_script(repo_root):
    build_file = repo_root / "build.sh"
    content = build_file.read_text(encoding="utf-8")
    insert_block = (
        '    DOC_DIR="/ffbuild/prefix/share/doc/ffmpeg"\n'
        '    echo "Checking DOC_DIR: \$DOC_DIR"\n'
        '    if [ -d "\$DOC_DIR" ]; then\n'
        '        echo "DOC_DIR exists. Listing content:"\n'
        '        ls -F "\$DOC_DIR"\n'
        '        # Try to install pandoc if missing, or download static binary\n'
        '        if ! command -v pandoc >/dev/null 2>&1; then\n'
        '            echo "Pandoc not found. Attempting installation..."\n'
        '            if [ "\$(id -u)" -eq 0 ]; then\n'
        '                echo "Running as root. Installing via apt..."\n'
        '                apt-get -y update\n'
        '                apt-get -y install --no-install-recommends pandoc\n'
        '            else\n'
        '                echo "Not root (UID: \$(id -u)). Downloading static pandoc..."\n'
        '                PANDOC_VER="3.8.3"\n'
        '                ARCH="\$(uname -m)"\n'
        '                PANDOC_ARCH=""\n'
        '                if [ "\$ARCH" = "x86_64" ]; then PANDOC_ARCH="amd64"; \n'
        '                elif [ "\$ARCH" = "aarch64" ]; then PANDOC_ARCH="arm64"; fi\n'
        '                if [ -n "\$PANDOC_ARCH" ]; then\n'
        '                    echo "Downloading pandoc-\${PANDOC_VER}-linux-\${PANDOC_ARCH}.tar.gz ..."\n'
        '                    wget -q -O pandoc.tar.gz "https://github.com/jgm/pandoc/releases/download/\${PANDOC_VER}/pandoc-\${PANDOC_VER}-linux-\${PANDOC_ARCH}.tar.gz"\n'
        '                    if [ -f pandoc.tar.gz ]; then\n'
        '                        echo "Download successful. Extracting..."\n'
        '                        tar -xf pandoc.tar.gz\n'
        '                        export PATH="\$PWD/pandoc-\${PANDOC_VER}/bin:\$PATH"\n'
        '                        echo "Pandoc path updated: \$(command -v pandoc)"\n'
        '                        pandoc --version | head -n 1\n'
        '                    else\n'
        '                        echo "Download failed!"\n'
        '                    fi\n'
        '                else\n'
        '                     echo "Unsupported architecture for static pandoc: \$ARCH"\n'
        '                fi\n'
        '            fi\n'
        '        else\n'
        '            echo "Pandoc already installed: \$(command -v pandoc)"\n'
        '        fi\n'
        '        if command -v pandoc >/dev/null 2>&1; then\n'
        '            echo "Starting HTML to Markdown conversion..."\n'
        '            find "\$DOC_DIR" -type f -name "*.html" -print0 | while IFS= read -r -d "" html; do\n'
        '                base="\$(basename "\$html" .html)"\n'
        '                echo "Converting \$base.html -> \$base.md"\n'
        '                pandoc -f html -t markdown "\$html" -o "\$DOC_DIR/\$base.md"\n'
        '            done\n'
        '        else\n'
        '            echo "Pandoc command not found, skipping Markdown generation."\n'
        '        fi\n'
        '        if command -v makeinfo >/dev/null 2>&1; then\n'
        '            echo "Starting Texi to Text conversion..."\n'
        '            for texi in doc/*.texi; do\n'
        '                [ -f "\$texi" ] || continue\n'
        '                base="\$(basename "\$texi" .texi)"\n'
        '                echo "Converting \$base.texi -> \$base.txt"\n'
        '                makeinfo --force --no-headers -o "\$DOC_DIR/\$base.txt" "\$texi"\n'
        '            done\n'
        '        else\n'
        '            echo "makeinfo command not found, skipping Text generation."\n'
        '        fi\n'
        '        echo "Final DOC_DIR content:"\n'
        '        ls -F "\$DOC_DIR"\n'
        '        # Cleanup if we downloaded\n'
        '        if [ -n "\$PANDOC_VER" ] && [ -d "pandoc-\${PANDOC_VER}" ]; then\n'
        '            rm -rf "pandoc-\${PANDOC_VER}" pandoc.tar.gz\n'
        '        fi\n'
        '        # Cleanup if we installed via apt\n'
        '        if [ "\$(id -u)" -eq 0 ] && command -v pandoc >/dev/null 2>&1; then\n'
        '             apt-get -y purge pandoc || true\n'
        '             apt-get -y autoremove\n'
        '             apt-get -y clean\n'
        '             rm -rf /var/lib/apt/lists/*\n'
        '        fi\n'
        '    else\n'
        '        echo "DOC_DIR \$DOC_DIR does not exist! Skipping doc generation."\n'
        "    fi\n"
    )
    anchor = "    make install install-doc\n"
    if insert_block in content:
        return
    if anchor not in content:
        raise RuntimeError("build.sh anchor not found")
    content = content.replace(anchor, anchor + insert_block)
    build_file.write_text(content, encoding="utf-8")


def patch_build_workflow(workflow_file):
    YAML = ensure_ruamel()
    yaml = YAML()
    yaml.preserve_quotes = True
    data = yaml.load(workflow_file.read_text(encoding="utf-8"))
    jobs = data.get("jobs", {})
    pre_check = jobs.get("pre_check", {})
    pre_check_steps = pre_check.get("steps", [])
    if pre_check_steps and isinstance(pre_check_steps[0], dict):
        run_text = pre_check_steps[0].get("run")
        if isinstance(run_text, str):
            pre_check_steps[0]["run"] = run_text.replace(
                "BtbN/FFmpeg-Builds", "${{ github.repository }}"
            )
    on_section = data.get("on")
    if not isinstance(on_section, dict):
        on_section = {}
        data["on"] = on_section
    on_section.pop("push", None)
    on_section.pop("schedule", None)
    on_section["schedule"] = [{"cron": "37 17 * * 6"}]
    variants = [
        "nonfree",
        "nonfree-shared",
        "nonfree 8.0",
        "nonfree-shared 8.0",
        "nonfree-shared 7.1",
    ]
    base_targets = ["win64", "winarm64", "linux64", "linuxarm64"]
    build_targets = ["win64", "winarm64", "linux64", "linuxarm64"]
    for job_key, targets in (
        ("build_target_bases", base_targets),
        ("build_targets", build_targets),
        ("build_ffmpeg", build_targets),
    ):
        job = jobs.get(job_key)
        if not isinstance(job, dict):
            continue
        strategy = job.setdefault("strategy", {})
        matrix = strategy.setdefault("matrix", {})
        matrix["target"] = targets
        if job_key in {"build_targets", "build_ffmpeg"}:
            matrix["variant"] = variants
    publish_release = jobs.get("publish_release", {})
    publish_steps = publish_release.get("steps", [])
    for step in publish_steps:
        if not isinstance(step, dict):
            continue
        if step.get("name") not in {"Create release", "Update Latest"}:
            continue
        run_text = step.get("run")
        if isinstance(run_text, str):
            step["run"] = re.sub(
                r'--target\s+["\']master["\']',
                '--target "${{ github.event.repository.default_branch }}"',
                run_text,
            )
    with workflow_file.open("w", encoding="utf-8") as handle:
        yaml.dump(data, handle)


def main():
    repo_root = Path(__file__).resolve().parents[2]
    workflow_file = repo_root / ".github" / "workflows" / "build.yml"
    patch_build_workflow(workflow_file)
    patch_build_script(repo_root)


if __name__ == "__main__":
    main()
