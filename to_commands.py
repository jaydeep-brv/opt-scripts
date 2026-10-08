# read panoptix.csv and form command
# name and secret columns will be used.
import csv

gitHub_url = "https://raw.githubusercontent.com/jaydeep-brv/opt-scripts/refs/heads/main/install_penoptix.sh"
curl_command = f"curl -fsSL {gitHub_url}"

with open('panoptix.csv', 'r') as file, open('to_commands.txt', 'w') as output_file:
    reader = csv.DictReader(file)
    for row in reader:
        name = row['name']
        secret = row['secret']
        header = f" [ {name} ] [ v: ] \n {curl_command} | bash -s -- {name} {secret} \n ================================"
        output_file.write(header + '\n')