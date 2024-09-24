import os
import shutil
from pathlib import Path

# Specify the source directory and the directory for copying
source_directory = "~/Desktop/Unsort/"  # Specify the path to the source directory
destination_directory = "~/Desktop/CD_Pics/"  # Specify the path to the destination directory

# Expand the user directory (~) to the full path
source_directory = os.path.expanduser(source_directory)
destination_directory = os.path.expanduser(destination_directory)

# Convert relative paths to absolute paths
source_directory = os.path.abspath(source_directory)
destination_directory = os.path.abspath(destination_directory)

# Supported image formats
image_formats = {'.jpg', '.jpeg', '.bmp', '.tiff', '.webp'}

# Create the destination directory if it doesn't exist
Path(destination_directory).mkdir(parents=True, exist_ok=True)

# Counter for copied files
copied_files_count = 0

# Walk through all files and subdirectories in the source directory
for root, dirs, files in os.walk(source_directory):
    print(f"Checking directory: {root}")  # Logging the current directory
    for file in files:
        file_path = os.path.join(root, file)
        # Check if the file is an image
        if file.lower().endswith(tuple(image_formats)):
            print(f"Image found: {file_path}")  # Logging the found image
            # Path for copying the file
            destination_path = os.path.join(destination_directory, file)
            try:
                # Copy the file
                shutil.copy2(file_path, destination_path)
                copied_files_count += 1
                print(f"Copied: {file_path} -> {destination_path}")
            except Exception as e:
                print(f"Error copying {file_path}: {e}")

# Final output
if copied_files_count > 0:
    print(f"Copying completed. {copied_files_count} files copied.")
else:
    print("No images found or copying not performed.")