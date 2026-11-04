// Format helpers for report output.

function padLeft(value, width) {
  return String(value).padStart(width, ' ');
}

function truncate(text, limit) {
  if (text.length <= limit) return text;
  return text.slice(0, limit - 1) + '.';
}

function joinFields(fields) {
  return fields.map(function (f) { return padLeft(f, 10); }).join(' ');
}

module.exports = { padLeft: padLeft, truncate: truncate, joinFields: joinFields };
