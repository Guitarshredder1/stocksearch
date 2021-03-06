#!/usr/bin/env python2
import threading
import csv
import time
import urllib2
import os
import sys
import json
import grequests as requests
import pickle
import pandas
import io
from datetime import datetime
import resource

resource.setrlimit(resource.RLIMIT_NOFILE, (110000, 110000))

executable_path = "/home/aidan/stocks/"
exchange_path = "/home/aidan/stocks/exchanges/"
stock_path = "/home/aidan/stocks/data/"
proc_path = "/home/aidan/stocks/proc/"
optionPath = "/home/aidan/stocks/options/"
block = 32768
optionURL = "https://query1.finance.yahoo.com/v7/finance/options/"

class Stock(threading.Thread):
	def __init__(self, symbol):
		super(Stock, self).__init__()
		self.success = False
		self.symbol = symbol
		self.session = requests.Session()

	def run(self):
		crumbFile =  self.session.get("https://finance.yahoo.com/quote/"+self.symbol+"?p="+self.symbol)
		if crumbFile.ok:
			print "Got to start"
			if "CrumbStore" in crumbFile.text:
				substr = crumbFile.text[crumbFile.text.find("\"CrumbStore"):crumbFile.text[crumbFile.text.find("CrumbStore"):].find(',')+crumbFile.text.find("CrumbStore")]
				substr = '{' + substr + '}'
				j = json.loads(substr)
				self.data = self.session.get("https://query1.finance.yahoo.com/v7/finance/download/"+self.symbol+"?period1=0000000000&period2=" + str(int(time.time())) + "&interval=1d&events=history&crumb="+j["CrumbStore"]["crumb"])
				options = self.session.get(optionURL + self.symbol)
				if options.ok:
					self.optionData = options.text
					self.success = True
				else:
					print optionURL + self.symbol + " URL Not Found"

		if self.success:
			print "Starting " + self.symbol
			with open(optionPath + self.symbol + '.csv', 'w') as optionFile:
				procOptionData = json.loads(self.optionData)
				for date in procOptionData['optionChain']['result'][0]['expirationDates']:
					curOptionGet = self.session.get(optionURL + self.symbol + "?date=" + str(date))
					if curOptionGet.ok:
						curOptionData = curOptionGet.text
						processed = json.loads(curOptionData)
						for item in processed['optionChain']['result'][0]['options'][0]['puts']:
							optionFile.write("P" + ',' + str(date) + ',' + str(item['strike']) + "," + str(item['bid']) + "," + str(item['ask']) + "," + str(item["impliedVolatility"])+'\n')
						for item in processed['optionChain']['result'][0]['options'][0]['calls']:
							optionFile.write("C" + ',' + str(date) + ',' + str(item['strike']) + "," + str(item['bid']) + "," + str(item['ask']) + "," + str(item["impliedVolatility"])+'\n')

					else:
						print optionURL + self.symbol + " URL Not Found" + "?date=" + str(date)
						return

				with open(proc_path + self.symbol + ".csv", 'w') as file:
					readin = pandas.read_csv(io.StringIO(self.data.text), header=0)
					readin.drop(columns=['Adj Close'])
					file.write(readin.to_csv(header=False, index=False))
				os.system(executable_path + "calc " + self.symbol)
		
class Exch():
	def __init__(self, exchange):
		self.exchange = exchange
		self.filepath = exchange_path + exchange + ".csv"
		self.url = urllib2.urlopen("https://www.nasdaq.com/screening/companies-by-name.aspx?letter=0&exchange="+self.exchange+"&render=download")
		self.file = open(self.filepath, "w")

		while True:
			buf = self.url.read(block)
			if not buf:
				break
			self.file.write(buf)

		self.file.close()

def main():
	exchanges = []
	exchanges.append(Exch("nasdaq"))
	symbols = []
	if len(sys.argv) < 2:
		for item in exchanges:
				with open(item.filepath, 'r') as file:
					reader = csv.DictReader(file)
					for row in reader:
						if row['Symbol'] not in symbols and " " not in row['Symbol']:
							symbols.append(row['Symbol'])
	else:
		count = 0
		for item in sys.argv:
			if count > 0:
				symbols.append(item)
			count = count+1

	threads = []

	for stock in symbols:
		start = datetime.now()
		print stock
		thread = Stock(stock)
		thread.start()
		threads.append(thread)

	for thread in threads:
		thread.join()

if __name__ == '__main__':
	main()
