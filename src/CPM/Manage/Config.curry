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
  bannerText = "cpm-manage (Version of 26/01/2021)"
  bannerLine = take (length bannerText) (repeat '-')

--- Base URL of CPM documentations
cpmDocURL :: String
cpmDocURL = "https://www-ps.informatik.uni-kiel.de/~cpm/DOC/"

--- Subdirectory containing HTML files for each package
--- generated by `cpm-manage genhtml`.
packageHtmlDir :: String
packageHtmlDir = "pkgs"

--- The default directory containing all package documentations
--- generated by `cypm doc`.
packageDocDir :: String
packageDocDir = "CPM" </> "DOC"

--- The default directory containing tar files of all packages.
packageTarDir :: String
packageTarDir = "CPM" </> "PACKAGES"

--- Directory with documentations for Currygle.
currygleDocDir :: String
currygleDocDir = "currygledocs"

-- Home page of PAKCS
pakcsURL :: String
pakcsURL = "http://www.informatik.uni-kiel.de/~pakcs/"

-- Home page of KiCS2
kics2URL :: String
kics2URL = "http://www-ps.informatik.uni-kiel.de/kics2/"

------------------------------------------------------------------------------
