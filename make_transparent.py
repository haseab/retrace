#!/usr/bin/env python3
"""
Script to make white backgrounds transparent in app icons.
"""

from PIL import Image
import os
from pathlib import Path

def make_white_transparent(image_path, threshold=240):
    """
    Make white (and near-white) pixels transparent in an image.

    Args:
        image_path: Path to the image file
        threshold: RGB value threshold (0-255). Pixels with R, G, and B all >= threshold become transparent
    """
    # Open the image
    img = Image.open(image_path)

    # Convert to RGBA if not already
    img = img.convert("RGBA")

    # Get pixel data
    data = img.getdata()

    # Create new pixel data with white pixels made transparent
    new_data = []
    for item in data:
        # If pixel is white (or near-white based on threshold), make it transparent
        if item[0] >= threshold and item[1] >= threshold and item[2] >= threshold:
            new_data.append((255, 255, 255, 0))  # Transparent
        else:
            new_data.append(item)

    # Update image data
    img.putdata(new_data)

    # Save the image
    img.save(image_path, "PNG")
    print(f"✓ Processed: {image_path.name}")

def process_icons_directory(directory):
    """Process all PNG files in a directory."""
    path = Path(directory)
    if not path.exists():
        print(f"✗ Directory not found: {directory}")
        return 0

    png_files = sorted(path.glob("*.png"))
    print(f"\nProcessing {len(png_files)} PNG files in {path.name}/")

    processed = 0
    for png_file in png_files:
        try:
            make_white_transparent(png_file)
            processed += 1
        except Exception as e:
            print(f"✗ Error processing {png_file.name}: {e}")

    return processed

if __name__ == "__main__":
    # Process both icon directories
    directories = [
        "/Users/haseab/Desktop/retrace/AppIcon.iconset",
        "/Users/haseab/Desktop/retrace/UI/Assets.xcassets/AppIcon.appiconset"
    ]

    total_processed = 0
    for directory in directories:
        total_processed += process_icons_directory(directory)

    print(f"\n✓ Done! Processed {total_processed} icons total.")
