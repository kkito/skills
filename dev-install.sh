#!/usr/bin/env bash
set -euo pipefail

# Dev install script: symlink all skills from skills/ to .qwen/skills/
# Safe to run multiple times — always syncs to current state.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_SOURCE_DIR="${SCRIPT_DIR}/skills"
SKILLS_TARGET_DIR="${SCRIPT_DIR}/.qwen/skills"

echo "🔗 Dev installing skills..."
echo "   Source: ${SKILLS_SOURCE_DIR}"
echo "   Target: ${SKILLS_TARGET_DIR}"

# Create target directory if it doesn't exist
mkdir -p "${SKILLS_TARGET_DIR}"

# Remove stale symlinks in target directory
if [ -d "${SKILLS_TARGET_DIR}" ]; then
  for link in "${SKILLS_TARGET_DIR}"/*/; do
    if [ -L "$link" ]; then
      target_of_link="$(readlink "$link")"
      if [ ! -d "$target_of_link" ]; then
        echo "   🗑  Removing stale symlink: $(basename "$link")"
        rm "$link"
      fi
    fi
  done
fi

# Symlink each skill
skill_count=0
for skill_dir in "${SKILLS_SOURCE_DIR}"/*/; do
  [ -d "$skill_dir" ] || continue
  
  skill_name="$(basename "$skill_dir")"
  target_link="${SKILLS_TARGET_DIR}/${skill_name}"
  
  # Skip if already linked correctly
  if [ -L "$target_link" ]; then
    existing_target="$(readlink "$target_link")"
    if [ "$existing_target" = "$skill_dir" ]; then
      echo "   ✅ ${skill_name} (already linked)"
      continue
    fi
  fi
  
  # Remove existing file/link if it exists
  if [ -e "$target_link" ] || [ -L "$target_link" ]; then
    rm -rf "$target_link"
  fi
  
  # Create symlink
  ln -s "$skill_dir" "$target_link"
  echo "   🔗 ${skill_name}"
  ((skill_count++))
done

echo ""
echo "✨ Done! ${skill_count} skill(s) installed."
echo "   Run this script again after adding new skills to sync."
