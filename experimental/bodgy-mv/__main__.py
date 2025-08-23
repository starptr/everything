import os
import shutil
from pathlib import Path
import re

def move_and_update_paths(src_dir: str, dst_dir: str, project_root: str):
    src_dir = Path(src_dir).resolve()
    dst_dir = Path(dst_dir).resolve()
    project_root = Path(project_root).resolve()

    if not src_dir.exists():
        raise FileNotFoundError(f"Source directory {src_dir} does not exist.")
    if not project_root.exists():
        raise FileNotFoundError(f"Project root {project_root} does not exist.")

    # Move the directory
    print(f"Moving {src_dir} -> {dst_dir}")
    shutil.move(str(src_dir), str(dst_dir))

    # Regex to match relative paths starting with ./ or ../
    relative_path_pattern = re.compile(r'(?P<quote>["\'])(\./|\.\./)([^"\']+)(?P=quote)')

    for file_path in project_root.rglob('*'):
        if file_path.is_file():
            content = file_path.read_text(encoding='utf-8')
            modified = False

            def replace_relative(match):
                old_path_str = match.group(2) + match.group(3)
                old_path = (file_path.parent / old_path_str).resolve()
                
                # Check if the path was inside the moved directory
                try:
                    old_path.relative_to(dst_dir.parent)  # Check relative to the new parent
                except ValueError:
                    # Not affected, return original
                    return match.group(0)
                
                # Compute new relative path from the file
                new_rel_path = os.path.relpath(old_path, file_path.parent)
                modified_path = match.group('quote') + new_rel_path.replace(os.sep, '/') + match.group('quote')
                nonlocal modified
                modified = True
                return modified_path

            new_content = relative_path_pattern.sub(replace_relative, content)
            if modified:
                file_path.write_text(new_content, encoding='utf-8')
                print(f"Updated paths in {file_path}")

if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Move directory subtree and update relative paths.")
    parser.add_argument("src", help="Source directory to move")
    parser.add_argument("dst", help="Destination directory")
    parser.add_argument("project_root", help="Root of the project where relative paths need updating")

    args = parser.parse_args()
    move_and_update_paths(args.src, args.dst, args.project_root)
