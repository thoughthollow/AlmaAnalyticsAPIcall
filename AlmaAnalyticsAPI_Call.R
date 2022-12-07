######
# TITLE: Get Electronic Portfolio Data from an Alma API using R
#
# More information on fetching user data can be found here:
# browseURL("https://developers.exlibrisgroup.com/alma/apis/analytics/")
#
# And here:
# browseURL("https://developers.exlibrisgroup.com/blog/Working-with-Analytics-REST-APIs/")
######

### General reference docs on XML parsing, and the XML2 package ###
# browseURL("https://lecy.github.io/Open-Data-for-Nonprofit-Research/Quick_Guide_to_XML_in_R.html")
# browseURL("https://www.rdocumentation.org/packages/xml2/versions/1.3.3")
#
# This has info on getting XML attributes and their names using "map()"
# browseURL(https://community.rstudio.com/t/generate-a-data-frame-from-many-xml-files/10214)
###...End...###
                                                                                                                  #

### Setup ###
# Load Packages
{
  library(tidyverse)
  library(httr)
  library(xml2)
}

# Create "output" sub-directory if it doesn't exist
if (!dir.exists("output")) {
  dir.create("output")
}

### setup End ###


# Load the private configuration data
{
  config <- read_csv("config.csv", # See configEXAMPLE.csv if the file doesn't exist
                     locale = locale(encoding = "UTF-8"),
                     trim_ws=TRUE)

  for (i in 1:ncol(config)) {
    assign(names(config)[i], as.character(config[,i]))
  }
  rm(i, config)
}

# Create the URL for the call
endpoint <- "almaws/v1/analytics/reports?"
limit <- 1000
col_names <- TRUE # Column heading information (NB: I've not tested FALSE; does it concern the schema info?)
url <- str_interp("${domain}${endpoint}path=${path}&limit=${limit}&col_names=${col_names}&apikey=${apikey}")


### Custom Functions ###

# Function to wrangle returned from an Alma Analytics API call
wrangleAAXML <- function() {

  # Prep the XML data for extraction
  x <- content(result, "parse") %>%
    pluck("anies") %>%
    unlist() %>%
    read_xml() %>%
    xml_ns_strip()

  # Get the variable for whether further calls are needed
  Finished <<- x %>%
    xml_find_all('//IsFinished') %>%
    xml_text() %>%
    as.logical() # Make it Boolean rather than a character class

  if (!Finished) {
    token <<- x %>%
      xml_find_all('//ResumptionToken') %>%
      xml_text()
  }

  ### XML Parsing... ###

  # Get the full path directory (under the initial <report> tag):
  # (This is useful for getting an overview of the data structure)
  struct <- x %>%
    xml_find_all( '//*') %>% xml_path() %>%
    tibble() %>%
    rename(structure = ".")

  # Get the number of "Column" Tags
  nTagCOL <- filter(struct, grepl("Column", structure)) %>%
    nrow() # I get this just for reference...

  # Get the number of "Row" Tags
  nTagROW <- filter(struct, grepl("Row", structure)) %>%
    nrow() - nTagCOL # I get this just for reference...


  if (!exists("key_COLHEADS")) { # Only get this object once, bc the schema and its elements only exists in the initial call.
    ### Key Table of Column Headings
    # Idea for this taken from the link below (I'm only roughly aware of how it works bc I'm only vaguely knowledgeable about the package "purrr"...):
    # https://community.rstudio.com/t/generate-a-data-frame-from-many-xml-files/10214
    key_COLHEADS <<- xml_find_all(x, "//xsd:element")
    key_COLHEADS <<- key_COLHEADS %>%
      map(xml_attrs) %>%
      map_df(~as.list(.))
    # The above gives nice metadata about the columns in Alma, but we don't need it.
    # So next, we select the rows we want (i.e. drop the others)
    key_COLHEADS <<- key_COLHEADS %>%
      select(name, columnHeading)
  }

  # Get the data into a tibble, with columns for the names and values
  AllRowTags <- xml_find_all(x, "//Row")

  df <- NULL
  RowNo = 1
  for (i in 1:length(AllRowTags)) {

    RowTag <- AllRowTags[i] %>% xml_children()
    RowTag.Names <- RowTag %>%
      map(xml_name)
    RowTag.Text <- RowTag %>%
      xml_text() %>% as.list()
    RowTag <- tibble(record = paste0("Row",RowNo), name = RowTag.Names, value = RowTag.Text)
    df <- rbind(df, RowTag)

    RowNo = RowNo + 1

  }

  # Make all columns have class "character"
  df <- df %>%
    mutate(name = as.character(name)) %>%
    mutate(value = as.character(value))
  # Clear up the environment
  rm(RowTag,RowTag.Names,RowTag.Text,i,RowNo)

  ### XML Parsing... End ###

  ### Join the data frames, then pivot it wide
  WideDF <-
    left_join(df, key_COLHEADS, by = "name") %>%
    select(-name) %>%
    pivot_wider(names_from = columnHeading, values_from = value)  %>%
    select(-"0",-record)

  # Order column names alphabetically
  WideDF <- WideDF[,order(colnames(WideDF), decreasing = TRUE)]


  ### Join to a data frame of multiple calls
  if(!exists("FinalDF")) { # Make a Final data frame for all the calls if it doesn't exist already
    FinalDF <- NULL
  }

  FinalDF <<- bind_rows(FinalDF,WideDF) %>% # Columns of the DFs can be of an uneven number, so "bind_rows" is needed stead of base R's "rbind"
    unique() # Get rid of any accidental duplicates while testing this script

}

Pivot_ISBNs <- function() {

  # Separate the deliminated column into multiple rows
  FinalDF <<- FinalDF %>%
    separate_rows(ISBN)

}

### Custom Functions End ###


# Call the API for the first time
result <- GET(url = url, add_headers("accept" = "application/json"))

if (status_code(result) != 200) {
  print(
    paste("Error code",status_code(result))
  )
} else {
  wrangleAAXML()
}

# If there are further records, then perform follow-up calls until all records are retrieved

if (!Finished) {
  newURL <- str_interp("${domain}${endpoint}token=${token}&limit=${limit}&col_names=${col_names}&apikey=${apikey}")

  # NOTE TO SELF: I should double check the documentation to see if there's something odd going
  # on with the limit parameter for resumption calls (i.e. calls that use TOKEN not PATH)

  while (Finished != TRUE) {
    result <- GET(url = newURL, add_headers("accept" = "application/json"))
    if (status_code(result) != 200) {
      print(
        paste("Error code", status_code(result))
      )
      break
    } else {
      wrangleAAXML()
    }
  }
}

### Check to see if the user wants to separate the ISBNs

# The below method requires the script to be run in RStudio
SepISBNS <- rstudioapi::showQuestion(
  title = "Response required",
  message = "Do you wish to separate the ISBNS into rows?",
  ok = "Yes",
  cancel = "No"
)
if (SepISBNS == TRUE) {
  Pivot_ISBNs()
}

# # This alternative method instead relies on base R
# keypress <- 0
# while (keypress != "y") {
#   keypress <- readline(prompt="Enter [y] into the console to separate the ISBNs by row; Enter [x] to not do so: ")
#   Sys.sleep(0.1)
#   if (keypress == "y") {
#
#     # Read in the html document
#     Pivot_ISBNs()
#
#   } else if (keypress == "x") {break}
# }


### write a .csv file
# Check to see if the user wants to write a file
allowWrite <- rstudioapi::showQuestion(
  title = "Response required",
  message = "Do you wish to save the data to a .csv file?",
  ok = "Yes",
  cancel = "No"
)

if (allowWrite == TRUE) {

  # Get the file name from the "path" variable
  fname <- substr(path, stringi::stri_locate_last(path, regex = "%2F") + 3, 1000)
  fname <- gsub("%20", "_", fname)

  # Output the .csv
  write_csv(FinalDF, file = paste0("output/",
                                   fname,
                                   format(Sys.time(), "%Y-%m-%dT%H.%M"),
                                   ".csv"))
  rstudioapi::showDialog(title = "Success",
                         message = "File created")
}
