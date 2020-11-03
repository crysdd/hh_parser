#!/usr/bin/env ruby
VERSION = "0.0.1"
# Парсер вакансий с hh.ru, на случай автономного ознакомления с оными.

require 'async'
require 'async/barrier'
require 'async/semaphore'
require 'async/http/internet'
require 'nokogiri'
require 'cgi'
require 'erb'

unless ARGV[0]
  puts "\n\tUsage: #{$0} <keyword>\n\n"
  exit
end
keyword = ARGV.join(" ") # на случай многословных запросов
hh = "https://omsk.hh.ru/search/vacancy?text=#{keyword}"
pages = []
vacancies = []
queue_size = 10 # ограничение количества одновременных запросов. Мы же не хотим их задосить?
Async do
# На самом деле в этом месте асинхронный вызов ни к чему, просто для однообразия
  internet = Async::HTTP::Internet.new
  barrier = Async::Barrier.new
  semaphore = Async::Semaphore.new(queue_size, parent: barrier)
  semaphore.async do
    response = internet.get hh
    doc = Nokogiri::HTML(response.read)
    # Проверяем, есть ли ещё страницы по запросу
    doc.xpath("//a[contains(@href,'page=')]/@href").each do |link|
      pages.push link.text
    end
    # Начинаем собирать урлы на страницы вакансий
    doc.xpath("//a[contains(@href,'/vacancy/')]/@href").each do |link|
      vacancies.push link.text if link.text.match('/vacancy/\d+')
    end
  end
  barrier.wait
ensure
  internet&.close
end
unless pages.empty? # Если вакансий на вторую страницу не хватило, пропускаем
  last_page = 0
  pages.each do |page|
    page_num = CGI::parse(page)["page"][0].to_i
    if  page_num > last_page.to_i
      last_page = page_num # по сути нам нужен только номер последней
    end
  end

  Async do
    internet = Async::HTTP::Internet.new
    barrier = Async::Barrier.new
    semaphore = Async::Semaphore.new(queue_size, parent: barrier)
    (1..last_page).each do |page|
      semaphore.async do
        response = internet.get hh + "&page=" + page.to_s
        doc = Nokogiri::HTML(response.read)
        doc.xpath("//a[contains(@href,'/vacancy/')]/@href").each do |link|
          vacancies.push link.text if link.text.match('/vacancy/\d+')
        end
      end
    end
    barrier.wait
  ensure
    internet&.close
  end
end

vacancies_folder = "articles_#{keyword}"
Dir.mkdir vacancies_folder unless File.exists?(vacancies_folder)
Async do
  internet = Async::HTTP::Internet.new
  barrier = Async::Barrier.new
  semaphore = Async::Semaphore.new(queue_size, parent: barrier)
  vacancies.each do |vacancy|
    semaphore.async do
      response = internet.get vacancy
      file = vacancy.gsub(/.*vacancy\/(\d+).*/, '\1')
      response.save("#{vacancies_folder}/#{file}.html")
    end
  end
  barrier.wait
ensure
  internet&.close
end

template = ERB.new %{
<!DOCTYPE html>
<html>
  <head>
    <title><%= keyword %></title>
    <meta charset="utf-8">
  </head>
  <body>
    <ul><% vacancies.each do |vacancy| %>
     <li><a href="<%= vacancy %>.html" target="_blank"><%= vacancy %></a></li>
    <%end %></ul>
  </body>
</html>
} #
vacancies.map! { |e| e.split('/').last.split("?").first }
File.write("#{vacancies_folder}/index.html", template.result)

system("xdg-open #{vacancies_folder}/index.html") # Не уверен на счет переносимости.




