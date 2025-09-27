#!/usr/bin/env python3
import argparse
import os
import subprocess as sub
import threading
import PySimpleGUI as sg

FRUITS = [
    "apple", "banana", "cherry", "date", "elderberry",
    "fig", "grape", "honeydew", "kiwi", "lemon",
    "mango", "nectarine", "orange", "papaya", "quince",
    "raspberry", "strawberry", "tangerine", "ugli", "watermelon"
]

SCRIPTS = {
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

DESCRIPTIONS = {
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

TROUBLE = {
    "cherry": "This script requires sudo. Ensure you have permission. If a password is needed, running via GUI without a TTY will hang.",
    "fig": "This script also runs with sudo. Check for missing dependencies.",
    "orange": "Runs as root. Ensure root can execute scripts in /scripts.",
    "kiwi": "May depend on /tmp data. Ensure it exists.",
    "default": "Verify the script exists, is executable, and works from a terminal.",
}

SPINNER_FRAMES = ['|', '/', '-', '\\']


def build_layout(unlock_all: bool):
    header = [sg.Text("Fruit", size=(14, 1)), sg.Text("Status", size=(18, 1)), sg.Text("Description", expand_x=True)]
    rows = []
    for i, f in enumerate(FRUITS):
        rows.append([
            sg.Button(f, key=("RUN", i), size=(14, 1), disabled=(not unlock_all and i != 0)),
            sg.Text("Ready" if (unlock_all or i == 0) else "Locked", key=("STATUS", i), size=(18, 1),
                    text_color="green" if (unlock_all or i == 0) else "gray"),
            sg.Text(DESCRIPTIONS.get(f, ""), key=("DESC", i), expand_x=True, justification="left")
        ])
    footer = [
        [sg.Text("Result:"), sg.Text("", key="RESULT", size=(80, 2), text_color="black")],
        [sg.Text("Troubleshooting:", text_color="darkred")],
        [sg.Multiline("", key="TROUBLE", size=(100, 4), disabled=True, autoscroll=True, no_scrollbar=True, text_color="darkred")]
    ]
    return [header] + rows + footer


def script_command(fruit: str):
    path = SCRIPTS[fruit]
    if fruit in ["cherry", "fig"]:
        return ["sudo", "bash", path]
    if fruit == "orange":
        return ["sudo", "-u", "root", "bash", path]
    return ["bash", path]


def run_script_worker(index: int, fruit: str, window: sg.Window):
    path = SCRIPTS[fruit]
    if not os.path.exists(path):
        window.write_event_value(("DONE", index), {"rc": None, "err": f"Script not found: {path}", "fruit": fruit})
        return
    cmd = script_command(fruit)
    try:
        proc = sub.Popen(cmd, stdout=sub.PIPE, stderr=sub.PIPE)
        out, err = proc.communicate()
        try:
            out = out.decode()
            err = err.decode()
        except Exception:
            pass
        window.write_event_value(("DONE", index), {"rc": proc.returncode, "out": out, "err": err, "fruit": fruit})
    except Exception as e:
        window.write_event_value(("DONE", index), {"rc": None, "err": str(e), "fruit": fruit})


def main():
    parser = argparse.ArgumentParser(description="Fruit Script Launcher GUI (PySimpleGUI)")
    parser.add_argument('--unlock-all', action='store_true', help="Unlock all buttons on launch")
    args = parser.parse_args()

    sg.set_options(font=("Segoe UI", 10))
    layout = build_layout(args.unlock_all)
    window = sg.Window("Fruit Script Launcher", layout, finalize=True, size=(900, 750), resizable=True)

    running = {i: False for i in range(len(FRUITS))}
    spin_idx = {i: 0 for i in range(len(FRUITS))}

    while True:
        event, values = window.read(timeout=100)
        if event == sg.WIN_CLOSED:
            break

        # animate
        for i, is_on in running.items():
            if is_on:
                frame = SPINNER_FRAMES[spin_idx[i] % len(SPINNER_FRAMES)]
                window[("STATUS", i)].update(f"Running {frame}", text_color="blue")
                spin_idx[i] += 1

        # button pressed
        if isinstance(event, tuple) and event[0] == "RUN":
            i = event[1]
            fruit = FRUITS[i]

            # disable current button
            window[("RUN", i)].update(disabled=True)
            running[i] = True
            spin_idx[i] = 0

            # clear result area
            window["RESULT"].update(f"Running {fruit} ...")
            window["TROUBLE"].update("")

            # start worker
            threading.Thread(target=run_script_worker, args=(i, fruit, window), daemon=True).start()

        # worker finished
        if isinstance(event, tuple) and event[0] == "DONE":
            i = event[1]
            payload = values[event]  # dict from write_event_value
            fruit = payload.get("fruit", FRUITS[i])
            running[i] = False

            rc = payload.get("rc")
            err = (payload.get("err") or "").strip()
            if rc == 0:
                window["RESULT"].update(f"✅ {fruit} executed successfully.")
                window[("STATUS", i)].update("Completed", text_color="green")
                # unlock next if not unlock-all
                # find current enable policy via first button; simpler: only lock/unlock when started locked
                if not args.unlock_all and i + 1 < len(FRUITS):
                    window[("RUN", i + 1)].update(disabled=False)
                    window[("STATUS", i + 1)].update("Ready", text_color="green")
            else:
                msg = f"❌ Error in {fruit}:\n{err if err else 'Unknown error'}" if rc is not None else f"⚠️ Failed to run {fruit}: {err}"
                window["RESULT"].update(msg)
                tip = TROUBLE.get(fruit, TROUBLE["default"])
                window["TROUBLE"].update(tip)
                window[("STATUS", i)].update("Failed", text_color="red")
                window[("RUN", i)].update(disabled=False)

    window.close()


if __name__ == "__main__":
    main()
