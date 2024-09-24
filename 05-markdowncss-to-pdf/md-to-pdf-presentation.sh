#!/bin/bash

# md-to-pdf-presentation.sh
# Script to convert a Markdown file to a PDF presentation with custom CSS, ensuring each header starts on a new page.

# Check if md-to-pdf is installed
if ! command -v md-to-pdf &> /dev/null
then
    echo "md-to-pdf could not be found. Please install it with: npm install -g md-to-pdf"
    exit 1
fi

# Check if the required arguments are provided
if [ $# -ne 2 ]; then
    echo "Usage: $0 <input_markdown_file> <stylesheet_css_file>"
    exit 1
fi

# Assign arguments to variables
INPUT_FILE="$1"
STYLESHEET_FILE="$2"

# Check if the input Markdown file exists
if [ ! -f "$INPUT_FILE" ]; then
    echo "Error: Markdown file '$INPUT_FILE' not found."
    exit 1
fi

# Check if the stylesheet file exists
if [ ! -f "$STYLESHEET_FILE" ]; then
    echo "Error: Stylesheet file '$STYLESHEET_FILE' not found."
    exit 1
fi

# Get the base name and directory of the input file
BASE_NAME=$(basename "$INPUT_FILE" .md)
INPUT_DIR=$(dirname "$INPUT_FILE")

# Define the output PDF file name and path
OUTPUT_FILE="${INPUT_DIR}/${BASE_NAME}.pdf"

# Create a unique temporary file to store the modified Markdown
TEMP_FILE=$(mktemp /tmp/temp_markdown_XXXXXX.md)

# Check if the temporary file creation was successful
if [ ! -f "$TEMP_FILE" ]; then
    echo "Error: Temporary file '$TEMP_FILE' could not be created."
    exit 1
fi

# Add page breaks using '---' before each top-level header (#) in the Markdown file
awk '/^# /{print "\n---\n"}{print}' "$INPUT_FILE" > "$TEMP_FILE"

# Generate the PDF using md-to-pdf with the provided stylesheet
echo "Generating PDF..."
md-to-pdf "$TEMP_FILE" --stylesheet "$STYLESHEET_FILE"

# Check if the PDF was created in the temporary directory
TEMP_PDF_FILE="${TEMP_FILE%.md}.pdf"
if [ -f "$TEMP_PDF_FILE" ]; then
    # Move the generated PDF to the desired location
    mv "$TEMP_PDF_FILE" "$OUTPUT_FILE"
    echo "PDF conversion completed successfully."
    echo "Generated PDF: $OUTPUT_FILE"
else
    echo "Error: PDF conversion failed. Check for errors above."
fi

# Remove the temporary file
rm "$TEMP_FILE"