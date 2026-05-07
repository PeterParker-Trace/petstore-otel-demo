"""
Locust load generator. Hits the frontend's API endpoints to produce realistic traffic.

Run locally with:    locust -f locustfile.py --host http://localhost:3000
Or headless:         locust -f locustfile.py --host http://localhost:3000 --users 10 --spawn-rate 2 --headless
"""

import random
from locust import HttpUser, task, between


class PetStoreUser(HttpUser):
    wait_time = between(1, 4)  # each simulated user waits 1-4s between actions

    @task(5)  # weight 5 — most common action
    def browse_pets(self):
        self.client.get("/api/pets", name="list pets")

    @task(2)
    def view_pet_detail(self):
        pet_id = random.randint(1, 8)
        with self.client.get(f"/api/pets/{pet_id}", name="view pet", catch_response=True) as resp:
            if resp.status_code == 404:
                resp.success()  # 404s on random IDs are expected, don't count as failures

    @task(1)
    def buy_pet(self):
        pet_id = random.randint(1, 8)
        payload = {
            "pet_id": pet_id,
            "quantity": random.randint(1, 2),
            "customer_email": f"user{random.randint(1, 1000)}@example.com",
        }
        with self.client.post("/api/orders", json=payload, name="buy pet", catch_response=True) as resp:
            # 402 (payment declined) and 409 (out of stock) are realistic outcomes, not failures.
            if resp.status_code in (402, 409):
                resp.success()
