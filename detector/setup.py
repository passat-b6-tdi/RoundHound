"""registers the RoundHound rounding direction detector as a Slither plugin

    pip install -e detector/
    slither . --detect roundhound-rounding-direction
"""
from setuptools import setup

setup(
    name="roundhound-detector",
    version="0.1.0",
    url="https://github.com/passat-b6-tdi/RoundHound",
    py_modules=["roundhound_detector"],
    install_requires=["slither-analyzer"],
    entry_points={"slither_analyzer.plugin": "roundhound = roundhound_detector:make_plugin"},
)
