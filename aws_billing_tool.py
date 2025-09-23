#!/usr/bin/env python3
import subprocess
import json
import datetime
import sys

# Try to import tabulate; if not installed, install it automatically
try:
    from tabulate import tabulate
except ImportError:
    print("📦 tabulate not found. Installing...")
    subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "tabulate"])
    from tabulate import tabulate

# ----- Helper Functions -----
def run_aws_cli(cmd):
    """Run AWS CLI command and return parsed JSON"""
    try:
        output = subprocess.check_output(cmd, shell=True)
        return json.loads(output.decode())
    except subprocess.CalledProcessError as e:
        print("\n❌ AWS CLI command failed!")
        print("Command:", cmd)
        print("Error:", e)
        print("\n💡 Make sure Cost Explorer is enabled and your IAM user has permissions:\n"
              "ce:GetCostAndUsage, ce:GetCostForecast, ce:GetUsageForecast, aws-portal:ViewBilling")
        sys.exit(1)

def format_usd(amount):
    return f"${float(amount):,.2f}"

def get_first_day_of_month(date):
    return date.replace(day=1)

def get_next_month_first_day(date):
    next_month = date.replace(day=28) + datetime.timedelta(days=4)  # always moves to next month
    return next_month.replace(day=1)

# ----- Cost Reports -----
def get_current_cost():
    start = get_first_day_of_month(datetime.date.today()).strftime("%Y-%m-%d")
    end = (datetime.date.today() + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    cmd = f'aws ce get-cost-and-usage --time-period Start={start},End={end} --granularity MONTHLY --metrics "UnblendedCost"'
    data = run_aws_cli(cmd)
    amount = data["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"]
    print(f"\n📊 Current month-to-date cost: {format_usd(amount)}\n")

def get_forecast():
    start = get_first_day_of_month(datetime.date.today()).strftime("%Y-%m-%d")
    end = get_next_month_first_day(datetime.date.today()).strftime("%Y-%m-%d")
    cmd = f'aws ce get-cost-forecast --time-period Start={start},End={end} --metric "UNBLENDED_COST" --granularity MONTHLY'
    data = run_aws_cli(cmd)
    amount = data["ForecastResultsByTime"][0]["MeanValue"]
    print(f"\n🔮 Forecasted spend for this month: {format_usd(amount)}\n")

def get_service_breakdown(top_n=10):
    start = get_first_day_of_month(datetime.date.today()).strftime("%Y-%m-%d")
    end = (datetime.date.today() + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    cmd = f'aws ce get-cost-and-usage --time-period Start={start},End={end} --granularity MONTHLY --metrics "UnblendedCost" --group-by Type=DIMENSION,Key=SERVICE'
    data = run_aws_cli(cmd)
    results = data["ResultsByTime"][0]["Groups"]
    services = []
    for g in results:
        service = g["Keys"][0]
        amount = float(g["Metrics"]["UnblendedCost"]["Amount"])
        if amount > 0:
            services.append((service, amount))
    services.sort(key=lambda x: x[1], reverse=True)
    print("\n🛠 Service-level breakdown (top services):")
    print(tabulate([(s[0], format_usd(s[1])) for s in services[:top_n]], headers=["Service", "Cost"]))
    print()

def get_daily_trend():
    start = get_first_day_of_month(datetime.date.today()).strftime("%Y-%m-%d")
    end = (datetime.date.today() + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    cmd = f'aws ce get-cost-and-usage --time-period Start={start},End={end} --granularity DAILY --metrics "UnblendedCost"'
    data = run_aws_cli(cmd)
    print("\n📅 Daily cost trend:")
    table = []
    for day in data["ResultsByTime"]:
        date = day["TimePeriod"]["Start"]
        amount = day["Total"]["UnblendedCost"]["Amount"]
        table.append([date, format_usd(amount)])
    print(tabulate(table, headers=["Date", "Cost"]))
    print()

def get_previous_month_comparison():
    today = datetime.date.today()
    first_day_current = get_first_day_of_month(today)
    first_day_prev = (first_day_current - datetime.timedelta(days=1)).replace(day=1)
    end_prev = first_day_current
    cmd = f'aws ce get-cost-and-usage --time-period Start={first_day_prev},End={end_prev} --granularity MONTHLY --metrics "UnblendedCost"'
    data = run_aws_cli(cmd)
    prev_amount = float(data["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"])
    # current month
    start = first_day_current.strftime("%Y-%m-%d")
    end = (today + datetime.timedelta(days=1)).strftime("%Y-%m-%d")
    cmd = f'aws ce get-cost-and-usage --time-period Start={start},End={end} --granularity MONTHLY --metrics "UnblendedCost"'
    data = run_aws_cli(cmd)
    current_amount = float(data["ResultsByTime"][0]["Total"]["UnblendedCost"]["Amount"])
    diff = current_amount - prev_amount
    diff_percent = (diff / prev_amount * 100) if prev_amount else 0
    print(f"\n📊 Previous month cost: {format_usd(prev_amount)}")
    print(f"💰 Current month-to-date cost: {format_usd(current_amount)}")
    print(f"📈 Change: {format_usd(diff)} ({diff_percent:.2f}%)\n")

def custom_date_report():
    start = input("Enter start date (YYYY-MM-DD): ")
    end = input("Enter end date (YYYY-MM-DD, exclusive): ")
    cmd = f'aws ce get-cost-and-usage --time-period Start={start},End={end} --granularity DAILY --metrics "UnblendedCost"'
    data = run_aws_cli(cmd)
    print(f"\n📅 Cost report from {start} to {end}:")
    table = []
    for day in data["ResultsByTime"]:
        date = day["TimePeriod"]["Start"]
        amount = day["Total"]["UnblendedCost"]["Amount"]
        table.append([date, format_usd(amount)])
    print(tabulate(table, headers=["Date", "Cost"]))
    print()

# ----- Interactive Menu -----
def menu():
    while True:
        print("=== AWS Billing Tool v2 ===")
        print("1) Current month-to-date cost")
        print("2) Forecasted cost for this month")
        print("3) Breakdown by service (top 10)")
        print("4) Daily cost trend")
        print("5) Previous month cost & comparison")
        print("6) Custom date range report")
        print("7) Exit")
        choice = input("👉 What do you want to check? ")
        if choice == "1":
            get_current_cost()
        elif choice == "2":
            get_forecast()
        elif choice == "3":
            get_service_breakdown()
        elif choice == "4":
            get_daily_trend()
        elif choice == "5":
            get_previous_month_comparison()
        elif choice == "6":
            custom_date_report()
        elif choice == "7":
            print("👋 Goodbye!")
            break
        else:
            print("❌ Invalid choice, try again.\n")

# ----- Main -----
if __name__ == "__main__":
    try:
        import tabulate
    except ImportError:
        print("📦 Missing dependency: tabulate. Installing...")
        subprocess.check_call([sys.executable, "-m", "pip", "install", "--user", "tabulate"])
    menu()