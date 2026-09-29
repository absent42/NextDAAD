import os
import subprocess
import sys

from vidtune import WAYLAND_TEXTINPUT_RULE, quiet_wayland_textinput


def test_linux_sets_rule():
    env = {}
    quiet_wayland_textinput(env, "linux")
    assert env["QT_LOGGING_RULES"] == WAYLAND_TEXTINPUT_RULE


def test_linux_keeps_user_rules_after_ours():
    env = {"QT_LOGGING_RULES": "qt.foo=true"}
    quiet_wayland_textinput(env, "linux")
    assert env["QT_LOGGING_RULES"] == WAYLAND_TEXTINPUT_RULE + ";qt.foo=true"


def test_linux_is_idempotent():
    env = {}
    quiet_wayland_textinput(env, "linux")
    quiet_wayland_textinput(env, "linux")
    assert env["QT_LOGGING_RULES"] == WAYLAND_TEXTINPUT_RULE


def test_other_platforms_untouched():
    for plat in ("win32", "darwin"):
        env = {"QT_LOGGING_RULES": "qt.foo=true"}
        quiet_wayland_textinput(env, plat)
        assert env == {"QT_LOGGING_RULES": "qt.foo=true"}


def _category_warning_enabled(rules):
    # Real Qt: the env var as vidtune sets it must mute the category.
    code = ("from PySide6.QtCore import QCoreApplication, QLoggingCategory\n"
            "app = QCoreApplication([])\n"
            "print(QLoggingCategory('qt.qpa.wayland.textinput').isWarningEnabled())\n")
    env = dict(os.environ, QT_LOGGING_RULES=rules)
    out = subprocess.run([sys.executable, "-c", code], env=env,
                         capture_output=True, text=True, timeout=60)
    return out.stdout.strip()


def test_rule_mutes_the_category_in_qt():
    env = {}
    quiet_wayland_textinput(env, "linux")
    assert _category_warning_enabled(env["QT_LOGGING_RULES"]) == "False"


def test_user_rule_can_turn_it_back_on():
    env = {"QT_LOGGING_RULES": WAYLAND_TEXTINPUT_RULE.replace("false", "true")}
    quiet_wayland_textinput(env, "linux")
    assert _category_warning_enabled(env["QT_LOGGING_RULES"]) == "True"
