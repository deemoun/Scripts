#!/bin/bash

# Universal path to Android Emulator
EMULATOR_PATH="$HOME/Library/Android/sdk/emulator/emulator"

# Check if emulator exists
if [ ! -f "$EMULATOR_PATH" ]; then
  echo "❌ Android Emulator not found at: $EMULATOR_PATH"
  exit 1
fi

# Get list of available AVDs
mapfile -t avd_list < <("$EMULATOR_PATH" -list-avds)

# Check if any AVDs are available
if [ ${#avd_list[@]} -eq 0 ]; then
  echo "❌ No AVDs available."
  exit 1
fi

# Display menu of available AVDs
echo -e "\nAvailable Android Virtual Devices:\n"
for i in "${!avd_list[@]}"; do
  printf "%d) %s\n" $((i+1)) "${avd_list[$i]}"
done

# Prompt for selection
echo -e "\nSelect an emulator (1-${#avd_list[@]}):"
read -r selection

# Validate input
if ! [[ "$selection" =~ ^[0-9]+$ ]]; then
  echo "❌ Invalid input. Please enter a number."
  exit 1
fi

index=$((selection - 1))
if [ $index -lt 0 ] || [ $index -ge ${#avd_list[@]} ]; then
  echo "❌ Selection out of range. Please select a valid number."
  exit 1
fi

# Get selected AVD name
selected_avd="${avd_list[$index]}"

# Launch the selected emulator
echo -e "\n🚀 Launching emulator: $selected_avd"
"$EMULATOR_PATH" -avd "$selected_avd" &
