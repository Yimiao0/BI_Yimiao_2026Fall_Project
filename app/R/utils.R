`%||%` <- function(x, y) if (is.null(x)) y else x

# Background jobs report progress by appending lines to a text file, which the
# app polls. Each line is "<fraction 0-1>\t<message>".
progress_writer <- function(path) {
  force(path)
  function(fraction, message) {
    line <- sprintf("%.3f\t%s %s", fraction, format(Sys.time(), "%H:%M:%S"), message)
    cat(line, "\n", file = path, append = TRUE, sep = "")
  }
}

read_progress <- function(path) {
  if (is.null(path) || !file.exists(path)) return(list(fraction = 0, log = character()))
  lines <- readLines(path, warn = FALSE)
  if (length(lines) == 0) return(list(fraction = 0, log = character()))
  parts <- strsplit(lines, "\t", fixed = TRUE)
  list(
    fraction = suppressWarnings(as.numeric(parts[[length(parts)]][1])),
    log = vapply(parts, function(p) paste(p[-1], collapse = "\t"), character(1))
  )
}
