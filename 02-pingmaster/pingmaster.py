import os
import platform

# Function to read websites from a file
def read_websites(file_name):
    with open(file_name, 'r') as file:
        websites = file.read().splitlines()
    return websites

# Function to ping a website based on the OS
def ping_website(website):
    # Detect the operating system
    current_os = platform.system()
    
    # Determine the appropriate ping command
    if current_os == "Windows":
        # Windows uses '-n' for the number of pings
        command = f"ping -n 4 {website}"
    else:
        # Mac/Linux use '-c' for the number of pings
        command = f"ping -c 4 {website}"
    
    response = os.system(command)
    if response == 0:
        print(f"Website {website} is reachable.")
    else:
        print(f"Website {website} is not reachable.")

def main():
    file_name = 'ping.txt'
    websites = read_websites(file_name)
    
    for website in websites:
        ping_website(website)

if __name__ == '__main__':
    main()
