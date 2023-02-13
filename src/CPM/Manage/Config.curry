------------------------------------------------------------------------------
--- Definition of some global constants used by the CPM manager.
------------------------------------------------------------------------------

module CPM.Manage.Config where

import System.FilePath  ( (</>) )

------------------------------------------------------------------------------
-- Some global settings:

-- Banner of the CPM manage tool:
banner :: String
banner = unlines [bannerLine, bannerText, bannerLine]
 where
  bannerText = "cpm-manage (Version of 13/02/2023)"
  bannerLine = take (length bannerText) (repeat '-')

--- The URL of the Curry homepage.
curryHomeURL :: String
curryHomeURL = "http://www.curry-lang.org"

--- The URL of the CPM homepage.
cpmHomeURL :: String
cpmHomeURL = "http://www.curry-lang.org/tools/cpm"

--- The URL of the package repository
cpmRepositoryURL :: String
cpmRepositoryURL = "https://cpm.informatik.uni-kiel.de"
-- cpmRepositoryURL = "https://www-ps.informatik.uni-kiel.de/~cpm" -- OLD

--- Base URL of CPM documentations
cpmDocURL :: String
cpmDocURL = cpmRepositoryURL </> "DOC/"

--- Subdirectory containing HTML files for each package
--- generated by `cpm-manage genhtml`.
packageHtmlDir :: String
packageHtmlDir = "pkgs"

--- Directory with documentations for Currygle.
currygleDocDir :: String
currygleDocDir = "currygledocs"

-- Home page of PAKCS
pakcsURL :: String
pakcsURL = "https://www.informatik.uni-kiel.de/~pakcs/"

-- Home page of KiCS2
kics2URL :: String
kics2URL = "https://www-ps.informatik.uni-kiel.de/kics2/"

-- Home page of Curry2Go
curry2goURL :: String
curry2goURL = "https://www-ps.informatik.uni-kiel.de/curry2go/"

------------------------------------------------------------------------------
