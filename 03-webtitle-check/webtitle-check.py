import urllib.request
from html.parser import HTMLParser

class TitleParser(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_title = False
        self.title = None

    def handle_starttag(self, tag, attrs):
        if tag.lower() == "title":
            self.in_title = True

    def handle_endtag(self, tag):
        if tag.lower() == "title":
            self.in_title = False

    def handle_data(self, data):
        if self.in_title:
            self.title = data

def get_website_title(url):
    try:
        # Fetch the webpage content
        with urllib.request.urlopen(url) as response:
            html_content = response.read().decode('utf-8')
        
        # Parse the HTML content
        parser = TitleParser()
        parser.feed(html_content)
        
        # Return the title or a message if no title was found
        return parser.title if parser.title else "No title found"

    except Exception as e:
        return f"An error occurred: {e}"

# Prompt user for a URL
url = input("Enter the URL: ").strip()

# Validate URL format
if not url.startswith("http://") and not url.startswith("https://"):
    url = "http://" + url

# Get and print the website title
title = get_website_title(url)
print(f"Website Title: {title}")
