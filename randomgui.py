import tkinter as tk
import subprocess
import os
import threading

class ButtonApp:
    def __init__(self, root):
        self.root = root
        self.root.title("Button Script Executor")

        # Dictionary to map each fruit to its script location
        self.scripts = {
            "apple": "/path/to/apple.sh",
            "banana": "/path/to/banana.sh",
            "cherry": "/path/to/cherry.sh",       # run with sudo ex
            "date": "/scripts/location/date.sh",
            "elderberry": "/some/location/elderberry.sh",
            "fig": "/path/to/fig.sh",             # run with sudo ex
            "grape": "/grape/scripts/grape.sh",
            "honeydew": "/different/path/honeydew.sh",
            "kiwi": "/kiwi/scripts/kiwi.sh",
            "lemon": "/path/to/lemon.sh",
            "mango": "/scripts/mango.sh",
            "nectarine": "/other/location/nectarine.sh",
            "orange": "/path/to/orange.sh",       # run as root ex
            "papaya": "/papaya/scripts/papaya.sh",
            "quince": "/quince/scripts/quince.sh",
            "raspberry": "/raspberry/scripts/raspberry.sh",
            "strawberry": "/strawberry/scripts/strawberry.sh",
            "tangerine": "/tangerine/scripts/tangerine.sh",
            "ugli": "/ugli/scripts/ugli.sh",
            "watermelon": "/watermelon/scripts/watermelon.sh",
        }

        self.fruits = list(self.scripts.keys())
        self.button_list = []

        self.result_text = tk.StringVar()
        self.result_label = tk.Label(root, textvariable=self.result_text, anchor="w", justify="left")
        self.result_label.grid(row=21, column=0, columnspan=5, sticky="w", pady=(10, 0))

        self.create_buttons()

    def create_buttons(self):
        for i in range(20):
            fruit = self.fruits[i]
            btn = tk.Button(
                self.root,
                text=f"{fruit.capitalize()}",
                command=lambda i=i: self.start_script_thread(i)
            )
            btn.grid(row=i // 5, column=i % 5, padx=5, pady=5)
            btn.config(state=tk.DISABLED)
            self.button_list.append(btn)

        # Enable the first button
        self.button_list[0].config(state=tk.NORMAL)

    def start_script_thread(self, index):
        thread = threading.Thread(target=self.run_script, args=(index,))
        thread.start()

    def run_script(self, button_index):
        fruit_name = self.fruits[button_index]
        script_path = self.scripts[fruit_name]

        # Disable the current button immediately to prevent double-click
        self.button_list[button_index].config(state=tk.DISABLED)

        if not os.path.exists(script_path):
            self.update_result(f"Script {fruit_name.capitalize()} not found at {script_path}.")
            return

        # Choose the correct command
        if fruit_name in ["cherry", "fig"]:
            command = ["sudo", "bash", script_path]
        elif fruit_name == "orange":
            command = ["sudo", "-u", "root", "bash", script_path]
        else:
            command = ["bash", script_path]

        try:
            process = subprocess.Popen(
                command,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE
            )
            stdout, stderr = process.communicate()
        except Exception as e:
            self.update_result(f"Failed to execute {fruit_name}: {str(e)}")
            self.button_list[button_index].config(state=tk.NORMAL)
            return

        # Check result
        if process.returncode == 0:
            self.update_result(f"{fruit_name.capitalize()} executed successfully.")
            if button_index + 1 < len(self.button_list):
                self.button_list[button_index + 1].config(state=tk.NORMAL)
        else:
            error_msg = stderr.decode().strip()
            self.update_result(f"Error in {fruit_name.capitalize()}: {error_msg}")
            # Re-enable the current button if execution failed
            self.button_list[button_index].config(state=tk.NORMAL)

    def update_result(self, message):
        # Update the result label in the GUI thread
        self.result_text.set(message)

# Launch the GUI
if __name__ == "__main__":
    root = tk.Tk()
    app = ButtonApp(root)
    root.mainloop()
