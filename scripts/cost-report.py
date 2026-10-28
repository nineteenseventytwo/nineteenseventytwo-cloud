#!/usr/bin/env python3
"""Weekly AWS cost report for Slack (.github/workflows/cost-report.yml).

Reads Cost Explorer and the budgets with the AWS CLI (no SDK on the runner),
and prints a Slack message as JSON on stdout. Prints nothing else: the repo is
public, and so are its run logs, so the figures go to Slack only.

Four Cost Explorer calls a run, at $0.01 each.
"""
import datetime as dt
import json
import subprocess
import sys

ACCOUNTS = {a["id"]: key for key, a in json.load(open("config/aws.json"))["accounts"].items()}
MGMT = next(a for a, k in ACCOUNTS.items() if k == "mgmt")
METRIC = "UnblendedCost"


def aws(*args):
    out = subprocess.run(["aws", *args, "--output", "json"], check=True, capture_output=True, text=True)
    return json.loads(out.stdout)


def cost(period, group=None):
    args = ["ce", "get-cost-and-usage", "--time-period", f"Start={period[0]},End={period[1]}",
            "--granularity", "DAILY", "--metrics", METRIC]
    if group:
        args += ["--group-by", f"Type=DIMENSION,Key={group}"]
    return aws(*args)["ResultsByTime"]


def total(days):
    return sum(float(d["Total"][METRIC]["Amount"]) for d in days)


def by_group(days):
    sums = {}
    for d in days:
        for g in d["Groups"]:
            sums[g["Keys"][0]] = sums.get(g["Keys"][0], 0.0) + float(g["Metrics"][METRIC]["Amount"])
    return sorted(sums.items(), key=lambda kv: -kv[1])


today = dt.date.today()
week = (today - dt.timedelta(days=7), today)
prev = (today - dt.timedelta(days=14), week[0])
month_start = today.replace(day=1)
next_month = (month_start + dt.timedelta(days=32)).replace(day=1)
iso = lambda p: (p[0].isoformat(), p[1].isoformat())

daily = cost(iso((prev[0], week[1])))
last7, prior7 = total(daily[7:]), total(daily[:7])
accounts = by_group(cost(iso(week), "LINKED_ACCOUNT"))
services = by_group(cost(iso(week), "SERVICE"))

mtd = total(cost(iso((month_start, today)))) if today > month_start else 0.0
try:
    forecast = float(aws("ce", "get-cost-forecast", "--time-period",
                         f"Start={today.isoformat()},End={next_month.isoformat()}",
                         "--metric", "UNBLENDED_COST", "--granularity", "MONTHLY")["Total"]["Amount"])
    month_forecast = f"${mtd + forecast:,.2f}"
except subprocess.CalledProcessError:
    month_forecast = "n/a (not enough history yet)"

budgets = aws("budgets", "describe-budgets", "--account-id", MGMT).get("Budgets", [])

change = last7 - prior7
arrow = "▲" if change > 0.005 else ("▼" if change < -0.005 else "=")
lines = [
    f"*AWS, week to {today:%a %d %b}*: ${last7:,.2f} {arrow} ${abs(change):,.2f} on the week before",
    f"Month to date ${mtd:,.2f}, forecast {month_forecast}",
]
for b in budgets:
    limit = float(b["BudgetLimit"]["Amount"])
    spent = float(b.get("CalculatedSpend", {}).get("ActualSpend", {}).get("Amount", 0))
    lines.append(f"Budget {b['BudgetName']}: ${spent:,.2f} of ${limit:,.2f} ({spent / limit:.0%})")
lines.append("By account: " + " · ".join(f"{ACCOUNTS.get(a, a)} ${v:,.2f}" for a, v in accounts if v >= 0.01))
lines.append("Top services: " + " · ".join(f"{s} ${v:,.2f}" for s, v in services[:5] if v >= 0.01))

json.dump({"text": "\n".join(lines)}, sys.stdout)
