from datetime import datetime

# Function to add a note to the file
def add_note():
    note = input("Enter your note: ")  # Ask user for input
    timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')  # Get current timestamp
    
    # Open the file in append mode
    with open("notes.txt", "a") as file:
        file.write(f"{timestamp}\n{note}\n\n")  # Append timestamp and note on separate lines, with an extra newline
    
    print("Note added successfully.")

# Run the add_note function once
if __name__ == "__main__":
    add_note()
