# Ping Websites Script

This Python script reads a list of websites from a file called `ping.txt` and pings each one to check if it is reachable. The script automatically detects the operating system (Windows, macOS, or Linux) and adjusts the ping command accordingly.

## Prerequisites

- Python 3.x
- A text file named `ping.txt` in the same directory as the script.

## Setup

### Create `ping.txt`:

Create a file named `ping.txt` in the same directory as the script. List the websites you want to ping, one per line. For example:


### Download the Script:

Save the Python script as `ping_websites.py` in the same directory as `ping.txt`.

## Usage

1. Open a terminal or command prompt.

2. Navigate to the directory containing `ping_websites.py` and `ping.txt`.

3. Run the script using the following command:

    ```bash
    python ping_websites.py
    ```

The script will automatically detect your operating system and use the appropriate `ping` command.

## Output

The script will display whether each website in `ping.txt` is reachable or not. Example output:


## Notes

- On Windows, the script uses the `ping -n` command.
- On macOS/Linux, the script uses the `ping -c` command.
- Ensure you have an active internet connection for accurate results.

## Troubleshooting

- **Permission Denied:** If you encounter a permission error, make sure you have read and write permissions for the directory.
- **Invalid Command:** Ensure the correct version of Python is being used (Python 3.x).

## License

This script is provided under the MIT License. You are free to use, modify, and distribute it as per the license terms.

---

This README provides a clear overview and instructions for setting up and using the script. Feel free to modify it based on your needs!
