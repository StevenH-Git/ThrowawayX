import tkinter as tk
import subprocess as sub
import os
import threading
import argparse
import sys

# python script.py
# or to enable all buttons,
# python script.py --unlock-all

#### use python3 if python points to python2 ###
# python3 script.py
# or to enable all buttons,
# python3 script.py --unlock-all

class ButtonApp:
    def __init__(self, root, unlock_all=False):
        self.root = root
        self.root.title("Fruit Script Launcher")

        self.unlock_all = unlock_all

        self.fruits = [
            "apple", "banana", "cherry", "date", "elderberry",
            "fig", "grape", "honeydew", "kiwi", "lemon",
            "mango", "nectarine", "orange", "papaya", "quince",
            "raspberry", "strawberry", "tangerine", "ugli", "watermelon"
        ]

        self.scripts = {
            "apple": "/scripts/apple.sh",
            "banana": "/scripts/banana.sh",
            "cherry": "/scripts/cherry.sh",
            "date": "/scripts/date.sh",
            "elderberry": "/scripts/elder.sh",
            "fig": "/scripts/fig.sh",
            "grape": "/scripts/grape.sh",
            "honeydew": "/scripts/honey.sh",
            "kiwi": "/scripts/kiwi.sh",
            "lemon": "/scripts/lemon.sh",
            "mango": "/scripts/smallfruit.sh",
            "nectarine": "/scripts/nectarine.sh",
            "orange": "/scripts/run_as_root.sh",
            "papaya": "/scripts/papaya.sh",
            "quince": "/scripts/quince.sh",
            "raspberry": "/scripts/rasp.sh",
            "strawberry": "/scripts/straw.sh",
            "tangerine": "/scripts/tanger.sh",
            "ugli": "/scripts/ugli.sh",
            "watermelon": "/scripts/water.sh",
        }

        self.descriptions = {
            "apple": "Runs apple script",
            "banana": "Runs banana script",
            "cherry": "Needs sudo privileges",
            "date": "Runs date script",
            "elderberry": "Runs elderberry script",
            "fig": "Needs sudo privileges",
            "grape": "Runs grape script",
            "honeydew": "Runs honeydew script",
            "kiwi": "Runs kiwi script",
            "lemon": "Runs lemon script",
            "mango": "Runs small fruit script",
            "nectarine": "Runs nectarine script",
            "orange": "Runs as root",
            "papaya": "Runs papaya script",
            "quince": "Runs quince script",
            "raspberry": "Runs raspberry script",
            "strawberry": "Runs strawberry script",
            "tangerine": "Runs tangerine script",
            "ugli": "Runs ugli fruit script",
            "watermelon": "Runs watermelon script",
        }

        self.button_list = []
        self.status_labels = []
        self.result_text = tk.StringVar()

        # Animation tracking
        self.anim_indices = [0] * len(self.fruits)
        self.anim_running = [False] * len(self.fruits)

        self.result_label = tk.Label(self.root, textvariable=self.result_text, anchor="w", justify="left")
        self.result_label.grid(row=len(self.fruits) + 1, column=0, columnspan=3, padx=10, pady=(20, 0), sticky="w")

        self.create_buttons()

    def create_buttons(self):
        for index, fruit in enumerate(self.fruits):
            btn = tk.Button(
                self.root,
                text=fruit,
                command=lambda i=index: self.start_script_thread(i),
                width=15
            )
            btn.grid(row=index, column=0, padx=10, pady=5, sticky="w")

            # Status label first (column 1)
            status_label = tk.Label(self.root, text="Preparing...", fg="gray")
            status_label.grid(row=index, column=1, padx=(10, 10), sticky="w")
            self.status_labels.append(status_label)

            # Description label second (column 2)
            desc = self.descriptions.get(fruit, "")
            desc_label = tk.Label(self.root, text=desc, anchor="w", justify="left")
            desc_label.grid(row=index, column=2, padx=(5, 10), sticky="w")

            # Enable buttons based on --unlock_all flag or normal sequential logic
            if self.unlock_all:
                btn.config(state=tk.NORMAL)
                status_label.config(text="Ready", fg="green")
            else:
                if index == 0:
                    btn.config(state=tk.NORMAL)
                    status_label.config(text="Ready", fg="green")
                else:
                    btn.config(state=tk.DISABLED)

            self.button_list.append(btn)

    def start_script_thread(self, index):
        thread = threading.Thread(target=self.run_script, args=(index,))
        thread.start()

    def run_script(self, button_index):
        fruit_name = self.fruits[button_index]
        script_path = self.scripts[fruit_name]

        self.button_list[button_index].config(state=tk.DISABLED)
        self.start_animation(button_index)

        if not os.path.exists(script_path):
            self.stop_animation(button_index)
            self.update_result(f"❌ Script not found: {script_path}")
            self.update_status(button_index, "Failed: Not Found", "red")
            self.button_list[button_index].config(state=tk.NORMAL)
            return

        if fruit_name in ["cherry", "fig"]:
            command = ["sudo", "bash", script_path]
        elif fruit_name == "orange":
            command = ["sudo", "-u", "root", "bash", script_path]
        else:
            command = ["bash", script_path]

        try:
            process = sub.Popen(
                command,
                stdout=sub.PIPE,
                stderr=sub.PIPE
            )
            stdout, stderr = process.communicate()
        except Exception as e:
            self.stop_animation(button_index)
            self.update_result(f"⚠️ Failed to run {fruit_name}: {str(e)}")
            self.update_status(button_index, "Failed", "red")
            self.button_list[button_index].config(state=tk.NORMAL)
            return

        self.stop_animation(button_index)

        if process.returncode == 0:
            self.update_result(f"✅ {fruit_name} executed successfully.")
            self.update_status(button_index, "Completed", "green")
            if not self.unlock_all:
                # Enable next button and update status to Ready.
                if button_index + 1 < len(self.button_list):
                    next_index = button_index + 1
                    self.button_list[next_index].config(state=tk.NORMAL)
                    self.update_status(next_index, "Ready", "green")
        else:
            error_msg = stderr.decode().strip()
            self.update_result(f"❌ Error in {fruit_name}:\n{error_msg}")
            self.update_status(button_index, "Failed", "red")
            self.button_list[button_index].config(state=tk.NORMAL)

    def update_status(self, index, text, color="black"):
        def callback():
            self.status_labels[index].config(text=text, fg=color)
        self.root.after(0, callback)

    def update_result(self, message):
        def callback():
            self.result_text.set(message)
        self.root.after(0, callback)

    # Spinner Animation! 

    def start_animation(self, index):
        self.anim_running[index] = True
        self.anim_indices[index] = 0
        self.animate_status(index)

    def stop_animation(self, index):
        self.anim_running[index] = False

    def animate_status(self, index):
        if not self.anim_running[index]:
            return

        spinner_frames = ['|', '/', '-', '\\']
        frame = spinner_frames[self.anim_indices[index] % len(spinner_frames)]
        status_text = f"Running {frame}"
        self.update_status(index, status_text, "blue")

        self.anim_indices[index] += 1
        self.root.after(100, lambda: self.animate_status(index))  # 100ms interval = 0.1 Seconds


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Fruit Script Launcher GUI")
    parser.add_argument('--unlock-all', action='store_true', help="Unlock (enable) all buttons on launch")
    args = parser.parse_args()

    root = tk.Tk()
    root.geometry("800x800")
    app = ButtonApp(root, unlock_all=args.unlock_all)
    root.mainloop()
