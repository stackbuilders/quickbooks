{-# LANGUAGE ImplicitParams     #-}
{-# LANGUAGE OverloadedStrings  #-}
{-# LANGUAGE RankNTypes         #-}

module QuickBooks.Authentication
  ( getTempOAuthCredentialsRequest
  , getAccessTokensRequest
  , oauthSignRequest
  , authorizationURLForToken
  , disconnectRequest
  ) where

import Control.Monad (void, liftM, ap)
import Data.Monoid ((<>))
import qualified Data.ByteString.Lazy as BSL
import Data.ByteString.Char8 (unpack, ByteString)
import QuickBooks.Types
import Network.HTTP.Client (Manager, Request(..), RequestBody(RequestBodyLBS), responseBody, parseUrl, httpLbs)
import Network.HTTP.Types.URI
import Web.Authenticate.OAuth (signOAuth, newCredential, emptyCredential, injectVerifier, newOAuth, OAuth(..))

import QuickBooks.Logging (logAPICall, Logger)

getTempOAuthCredentialsRequest :: ( ?apiConfig :: APIConfig
                                  , ?manager   :: Manager
                                  , ?logger    :: Logger                
                                  ) => CallbackURL
                                    -> IO (Either String (QuickBooksResponse OAuthToken)) -- ^ An OAuthToken with temporary credentials

getTempOAuthCredentialsRequest callbackURL =
  return.handleQuickBooksTokenResponse "Couldn't get temporary tokens" =<< tokensRequest
    where tokensRequest = getTokens temporaryTokenURL "?oauth_callback=" callbackURL oauthSignRequestWithEmptyCredentials

getAccessTokensRequest :: ( ?apiConfig :: APIConfig
                          , ?manager   :: Manager
                          , ?logger    :: Logger  
                          )  => OAuthToken                                         -- ^ The previously-acquired temp tokens to
                                                                                   --   use in signing this request
                             -> OAuthVerifier                                      -- ^ The OAuthVerifier provided to the callback
                             -> IO (Either String (QuickBooksResponse OAuthToken)) -- ^ OAuthToken containing access tokens
                                                                                   --   for a resource-owner
getAccessTokensRequest tempToken verifier =
  return.handleQuickBooksTokenResponse "Couldn't get access tokens" =<< tokensRequest
  where
    tokensRequest = getTokens accessTokenURL "?oauth_token=" (unpack $ token tempToken)
                                                             (oauthSignRequestWithVerifier verifier tempToken)

disconnectRequest :: ( ?apiConfig :: APIConfig
                     , ?manager   :: Manager
                     , ?logger    :: Logger                
                     ) => OAuthToken -> IO (Either String (QuickBooksResponse ()))
disconnectRequest tok = do
  req  <- parseUrl $ disconnectURL
  req' <- oauthSignRequest tok req
  void $ httpLbs req' ?manager
  logAPICall req'
  return $ Right QuickBooksVoidResponse
  
  
getTokens :: ( ?apiConfig :: APIConfig
             , ?manager   :: Manager
             , ?logger    :: Logger 
             ) => String                  -- ^ Endpoint to request the token
               -> String                  -- ^ URL parameter name
               -> String                  -- ^ URL parameter value
               -> ((?apiConfig :: APIConfig) => Request -> IO Request) -- ^ Signing function
               -> IO (Maybe OAuthToken)
getTokens tokenURL parameterName parameterValue signRequest = do
  request  <- parseUrl $ concat [tokenURL, parameterName, parameterValue]
  request' <- signRequest request { method="POST", requestBody = RequestBodyLBS "" }
  response <- httpLbs request' ?manager
  logAPICall request'
  return $ tokensFromResponse (responseBody response)


oauthSignRequestWithVerifier :: (?apiConfig :: APIConfig) => OAuthVerifier -> OAuthToken -> Request -> IO Request
oauthSignRequestWithVerifier verifier tempTokens = signOAuth oauthApp credsWithVerifier
  where
    credentials       = newCredential (token tempTokens)
                                      (tokenSecret tempTokens)
    credsWithVerifier = injectVerifier (unOAuthVerifier verifier) credentials
    oauthApp          = newOAuth { oauthConsumerKey    = consumerToken ?apiConfig
                                 , oauthConsumerSecret = consumerSecret ?apiConfig }


oauthSignRequest :: (?apiConfig :: APIConfig) => OAuthToken -> Request -> IO Request
oauthSignRequest tok req = signOAuth oauthApp credentials req
  where
    credentials = newCredential (token tok)
                                (tokenSecret tok)
    oauthApp    = newOAuth { oauthConsumerKey    = consumerToken ?apiConfig
                           , oauthConsumerSecret = consumerSecret ?apiConfig }

oauthSignRequestWithEmptyCredentials :: (?apiConfig :: APIConfig) => Request -> IO Request
oauthSignRequestWithEmptyCredentials = signOAuth oauthApp credentials
  where
    credentials = emptyCredential
    oauthApp    = newOAuth { oauthConsumerKey    = consumerToken ?apiConfig
                           , oauthConsumerSecret = consumerSecret ?apiConfig }

disconnectURL :: String
disconnectURL = "https://appcenter.intuit.com/api/v1/connection/disconnect"

accessTokenURL :: String
accessTokenURL = "https://oauth.intuit.com/oauth/v1/get_access_token"

temporaryTokenURL :: String
temporaryTokenURL = "https://oauth.intuit.com/oauth/v1/get_request_token"

authorizationURL :: ByteString
authorizationURL = "https://appcenter.intuit.com/Connect/Begin"

authorizationURLForToken :: OAuthToken -> ByteString 
authorizationURLForToken oatoken = authorizationURL <> "?oauth_token=" <> (token oatoken)
 
handleQuickBooksTokenResponse :: String -> Maybe OAuthToken -> Either String (QuickBooksResponse OAuthToken)
handleQuickBooksTokenResponse _ (Just tokensInResponse) = Right $ QuickBooksAuthResponse tokensInResponse
handleQuickBooksTokenResponse errorMessage Nothing      = Left errorMessage

tokensFromResponse :: BSL.ByteString -> Maybe OAuthToken
tokensFromResponse response = OAuthToken `liftM` lookup "oauth_token" responseParams
                                         `ap` lookup "oauth_token_secret" responseParams
  where responseParams = parseSimpleQuery (BSL.toStrict response)
