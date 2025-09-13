from setuptools import setup, find_packages

setup(name='graceful_shutdown',
    version='0.1.0',
    # Modules to import from other scripts:
    packages=find_packages(),
    # Executables
    scripts=["graceful-shutdown.py"],
)