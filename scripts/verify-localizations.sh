#!/bin/zsh

set -euo pipefail

project_root="${0:A:h:h}"

ruby -rjson - "$project_root" <<'RUBY'
root = ARGV.fetch(0)
sources = Dir.glob(File.join(root, "PEEK/**/*.swift"))
catalog_path = File.join(root, "PEEK/Resources/Localizable.xcstrings")
info_catalog_path = File.join(root, "PEEK/Resources/InfoPlist.xcstrings")
catalog = JSON.parse(File.read(catalog_path))
strings = catalog.fetch("strings")

abort "Localizable.xcstrings must use zh-Hans as its source language" unless
  catalog["sourceLanguage"] == "zh-Hans"

unlocalized = []
sources.reject { |path| path.end_with?("PEEKLocalization.swift") }.each do |path|
  source = File.read(path)
  source.to_enum(:scan, /"(?:\\.|[^"\\])*"/).each do
    match = Regexp.last_match
    literal = match[0]
    next unless literal.match?(/\p{Han}/)
    prefix = source[[match.begin(0) - 40, 0].max...match.begin(0)]
    next if prefix.match?(/L10n\.tr\(\s*$/)
    line = source[0...match.begin(0)].count("\n") + 1
    unlocalized << "#{path.delete_prefix(root + "/")}:#{line}:#{literal}"
  end
end
abort "Unlocalized Chinese literals:\n#{unlocalized.join("\n")}" unless unlocalized.empty?

source_keys = {}
sources.each do |path|
  File.read(path).scan(/L10n\.tr\(\s*("(?:\\.|[^"\\])*")/m) do |capture|
    source_keys[JSON.parse(capture[0])] = true
  end
end
missing = source_keys.keys - strings.keys
abort "Catalog is missing keys:\n#{missing.sort.join("\n")}" unless missing.empty?

format_specifiers = ->(value) { value.scan(/%(?:lld|@|d|u)/).sort }
strings.each do |key, entry|
  unit = entry.dig("localizations", "en", "stringUnit")
  value = unit && unit["value"]
  abort "Missing English translation: #{key}" if value.nil? || value.empty?
  abort "Format placeholder mismatch: #{key} -> #{value}" unless
    format_specifiers.call(key) == format_specifiers.call(value)
end

info = JSON.parse(File.read(info_catalog_path))
usage = info.dig("strings", "NSScreenCaptureUsageDescription", "localizations") || {}
%w[en zh-Hans].each do |language|
  abort "InfoPlist catalog is missing #{language}" unless usage.key?(language)
end

puts "Localization verification passed: #{source_keys.length} source keys, #{strings.length} catalog entries."
RUBY
