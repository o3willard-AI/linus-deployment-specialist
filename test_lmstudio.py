#!/usr/bin/env python3
import requests
import json

url = "http://192.168.101.21:1234/v1/models"
try:
    response = requests.get(url, timeout=5)
    print(f"Status: {response.status_code}")
    data = response.json()
    print(f"Models: {[m['id'] for m in data.get('data', [])]}")
except Exception as e:
    print(f"Error: {e}")