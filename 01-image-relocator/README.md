# Image Relocator Script

This Python script copies image files from a specified source directory to a destination directory without creating subfolders based on file dates. It supports multiple image formats and ensures that the images are organized in one location.

## Supported Image Formats
The script supports the following image formats:
- `.jpg`
- `.jpeg`
- `.bmp`
- `.tiff`
- `.webp`

## Prerequisites
- Python 3.x
- The `shutil` and `pathlib` libraries (these are included with the Python standard library)

## Installation
1. Clone this repository or download the script file to your local machine.
2. Make sure you have Python 3.x installed.

## Usage
1. Place the script file (`image_copier.py`) in your working directory.
2. Update the following variables in the script as needed:
   - `source_directory`: Path to the source directory containing images to be copied.
   - `destination_directory`: Path to the directory where the images will be copied.

    ```python
    source_directory = "Unsort/"  # Change this to your source directory
    destination_directory = "CD_Pics/"  # Change this to your destination directory
    ```

3. Run the script using the command line:

    ```bash
    python image_copier.py
    ```

4. The script will walk through all subdirectories in the source directory, find all images in supported formats, and copy them to the destination directory.

## Logging and Output
- The script will print the current directory it is checking.
- It will log each image found and copied, indicating both the source and destination paths.
- At the end, it will print a summary of the number of files copied.

## Error Handling
If the script encounters an error while copying a file, it will print an error message with the file path and the error description.

## License
This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

