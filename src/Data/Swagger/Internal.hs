{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE UndecidableInstances #-}
module Data.Swagger.Internal where

import Prelude ()
import Prelude.Compat

import           Control.Applicative
import           Control.Lens          ((&), (.~), (?~))
import           Data.Aeson            hiding (Encoding)
import qualified Data.Aeson.Types      as JSON
import           Data.Data             (Constr, Data (..), DataType, Fixity (..), Typeable,
                                        constrIndex, mkConstr, mkDataType)
import           Data.Hashable         (Hashable (..))
import qualified Data.HashMap.Strict   as HashMap
import           Data.HashSet.InsOrd   (InsOrdHashSet)
import           Data.Map              (Map)
import qualified Data.Map              as Map
import           Data.Monoid           (Monoid (..))
import           Data.Scientific       (Scientific)
import           Data.Semigroup.Compat (Semigroup (..))
import           Data.String           (IsString (..))
import           Data.Text             (Text)
import qualified Data.Text             as Text
import           Data.Text.Encoding    (encodeUtf8)
import           GHC.Generics          (Generic)
import           Network.HTTP.Media    (MediaType, mainType, parameters, parseAccept, subType, (//),
                                        (/:))
import           Network.Socket        (HostName, PortNumber)
import           Text.Read             (readMaybe)

import           Data.HashMap.Strict.InsOrd (InsOrdHashMap)
import qualified Data.HashMap.Strict.InsOrd as InsOrdHashMap

import Generics.SOP.TH                  (deriveGeneric)
import Data.Swagger.Internal.AesonUtils (sopSwaggerGenericToJSON
                                        ,sopSwaggerGenericToJSONWithOpts
                                        ,sopSwaggerGenericParseJSON
                                        ,HasSwaggerAesonOptions(..)
                                        ,AesonDefaultValue(..)
                                        ,mkSwaggerAesonOptions
                                        ,saoAdditionalPairs
                                        ,saoSubObject)
import Data.Swagger.Internal.Utils
import Data.Swagger.Internal.AesonUtils (sopSwaggerGenericToEncoding)

-- $setup
-- >>> :seti -XDataKinds
-- >>> import Data.Aeson

-- | A list of definitions that can be used in references.
type Definitions = InsOrdHashMap Text

-- | This is the root document object for the API specification.
data Swagger = Swagger
  { -- | Provides metadata about the API.
    -- The metadata can be used by the clients if needed.
    _swaggerInfo :: Info

    -- | An array of Server Objects, which provide connectivity information
    -- to a target server. If the servers property is not provided, or is an empty array,
    -- the default value would be a 'Server' object with a url value of @/@.
  , _swaggerServers :: [Server]

    -- | The available paths and operations for the API.
  , _swaggerPaths :: InsOrdHashMap FilePath PathItem

    -- | An element to hold various schemas for the specification.
  , _swaggerComponents :: Components

    -- | A declaration of which security mechanisms can be used across the API.
    -- The list of values includes alternative security requirement objects that can be used.
    -- Only one of the security requirement objects need to be satisfied to authorize a request.
    -- Individual operations can override this definition.
    -- To make security optional, an empty security requirement can be included in the array.
  , _swaggerSecurity :: [SecurityRequirement]

    -- | A list of tags used by the specification with additional metadata.
    -- The order of the tags can be used to reflect on their order by the parsing tools.
    -- Not all tags that are used by the 'Operation' Object must be declared.
    -- The tags that are not declared MAY be organized randomly or based on the tools' logic.
    -- Each tag name in the list MUST be unique.
  , _swaggerTags :: InsOrdHashSet Tag

    -- | Additional external documentation.
  , _swaggerExternalDocs :: Maybe ExternalDocs
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | The object provides metadata about the API.
-- The metadata MAY be used by the clients if needed,
-- and MAY be presented in editing or documentation generation tools for convenience.
data Info = Info
  { -- | The title of the API.
    _infoTitle :: Text

    -- | A short description of the API.
    -- [CommonMark syntax](https://spec.commonmark.org/) MAY be used for rich text representation.
  , _infoDescription :: Maybe Text

    -- | A URL to the Terms of Service for the API. MUST be in the format of a URL.
  , _infoTermsOfService :: Maybe Text

    -- | The contact information for the exposed API.
  , _infoContact :: Maybe Contact

    -- | The license information for the exposed API.
  , _infoLicense :: Maybe License

    -- | The version of the OpenAPI document (which is distinct from the
    -- OpenAPI Specification version or the API implementation version).
  , _infoVersion :: Text
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | Contact information for the exposed API.
data Contact = Contact
  { -- | The identifying name of the contact person/organization.
    _contactName  :: Maybe Text

    -- | The URL pointing to the contact information.
  , _contactUrl   :: Maybe URL

    -- | The email address of the contact person/organization.
  , _contactEmail :: Maybe Text
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | License information for the exposed API.
data License = License
  { -- | The license name used for the API.
    _licenseName :: Text

    -- | A URL to the license used for the API.
  , _licenseUrl :: Maybe URL
  } deriving (Eq, Show, Generic, Data, Typeable)

instance IsString License where
  fromString s = License (fromString s) Nothing

-- | An object representing a Server.
data Server = Server
  { -- | A URL to the target host. This URL supports Server Variables and MAY be relative,
    -- to indicate that the host location is relative to the location where
    -- the OpenAPI document is being served. Variable substitutions will be made when
    -- a variable is named in @{brackets}@.
    _serverUrl :: Text

    -- | An optional string describing the host designated by the URL.
    -- [CommonMark syntax](https://spec.commonmark.org/) MAY be used for rich text representation.
  , _serverDescription :: Maybe Text

    -- | A map between a variable name and its value.
    -- The value is used for substitution in the server's URL template.
  , _serverVariables :: InsOrdHashMap Text ServerVariable
  } deriving (Eq, Show, Generic, Data, Typeable)

data ServerVariable = ServerVariable
  { -- | An enumeration of string values to be used if the substitution options
    -- are from a limited set. The array SHOULD NOT be empty.
    _serverVariableEnum :: Maybe (InsOrdHashSet Text) -- TODO NonEmpty

    -- | The default value to use for substitution, which SHALL be sent if an alternate value
    -- is not supplied. Note this behavior is different than the 'Schema\ Object's treatment
    -- of default values, because in those cases parameter values are optional.
    -- If the '_serverVariableEnum' is defined, the value SHOULD exist in the enum's values.
  , _serverVariableDefault :: Text

    -- | An optional description for the server variable.
    -- [CommonMark syntax](https://spec.commonmark.org/) MAY be used for rich text representation.
  , _serverVariableDescription :: Maybe Text
  } deriving (Eq, Show, Generic, Data, Typeable)

instance IsString Server where
  fromString s = Server (fromString s) Nothing mempty

-- | Holds a set of reusable objects for different aspects of the OAS.
-- All objects defined within the components object will have no effect on the API
-- unless they are explicitly referenced from properties outside the components object.
data Components = Components
  { _componentsSchemas :: Definitions Schema
  , _componentsResponses :: Definitions Response
  , _componentsParameters :: Definitions Param
  , _componentsExamples :: Definitions Example
  , _componentsRequestBodies :: Definitions RequestBody
  , _componentsHeader :: Definitions Header
  , _componentsSecuritySchemes :: Definitions SecurityScheme
--  , _componentsLinks
--  , _componentsCallbacks
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | Describes the operations available on a single path.
-- A @'PathItem'@ may be empty, due to ACL constraints.
-- The path itself is still exposed to the documentation viewer
-- but they will not know which operations and parameters are available.
data PathItem = PathItem
  { -- | An optional, string summary, intended to apply to all operations in this path.
    _pathItemSummary :: Maybe Text

    -- | An optional, string description, intended to apply to all operations in this path.
    -- [CommonMark syntax](https://spec.commonmark.org/) MAY be used for rich text representation.
  , _pathItemDescription :: Maybe Text

    -- | A definition of a GET operation on this path.
  , _pathItemGet :: Maybe Operation

    -- | A definition of a PUT operation on this path.
  , _pathItemPut :: Maybe Operation

    -- | A definition of a POST operation on this path.
  , _pathItemPost :: Maybe Operation

    -- | A definition of a DELETE operation on this path.
  , _pathItemDelete :: Maybe Operation

    -- | A definition of a OPTIONS operation on this path.
  , _pathItemOptions :: Maybe Operation

    -- | A definition of a HEAD operation on this path.
  , _pathItemHead :: Maybe Operation

    -- | A definition of a PATCH operation on this path.
  , _pathItemPatch :: Maybe Operation

    -- | A definition of a TRACE operation on this path.
  , _pathItemTrace :: Maybe Operation

    -- | An alternative server array to service all operations in this path.
  , _pathItemServers :: [Server]

    -- | A list of parameters that are applicable for all the operations described under this path.
    -- These parameters can be overridden at the operation level, but cannot be removed there.
    -- The list MUST NOT include duplicated parameters.
    -- A unique parameter is defined by a combination of a name and location.
  , _pathItemParameters :: [Referenced Param]
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | Describes a single API operation on a path.
data Operation = Operation
  { -- | A list of tags for API documentation control.
    -- Tags can be used for logical grouping of operations by resources or any other qualifier.
    _operationTags :: InsOrdHashSet TagName

    -- | A short summary of what the operation does.
    -- For maximum readability in the swagger-ui, this field SHOULD be less than 120 characters.
  , _operationSummary :: Maybe Text

    -- | A verbose explanation of the operation behavior.
    -- [CommonMark syntax](https://spec.commonmark.org/) can be used for rich text representation.
  , _operationDescription :: Maybe Text

    -- | Additional external documentation for this operation.
  , _operationExternalDocs :: Maybe ExternalDocs

    -- | Unique string used to identify the operation.
    -- The id MUST be unique among all operations described in the API.
    -- The operationId value is **case-sensitive**.
    -- Tools and libraries MAY use the operationId to uniquely identify an operation, therefore,
    -- it is RECOMMENDED to follow common programming naming conventions.
  , _operationOperationId :: Maybe Text

    -- | A list of parameters that are applicable for this operation.
    -- If a parameter is already defined at the @'PathItem'@,
    -- the new definition will override it, but can never remove it.
    -- The list MUST NOT include duplicated parameters.
    -- A unique parameter is defined by a combination of a name and location.
  , _operationParameters :: [Referenced Param]

    -- | The request body applicable for this operation.
    -- The requestBody is only supported in HTTP methods where the HTTP 1.1
    -- specification [RFC7231](https://tools.ietf.org/html/rfc7231#section-4.3.1)
    -- has explicitly defined semantics for request bodies.
    -- In other cases where the HTTP spec is vague, requestBody SHALL be ignored by consumers.
  , _operationRequestBody :: Maybe (Referenced RequestBody)

    -- | The list of possible responses as they are returned from executing this operation.
  , _operationResponses :: Responses

    -- TODO callbacks

    -- | Declares this operation to be deprecated.
    -- Usage of the declared operation should be refrained.
    -- Default value is @False@.
  , _operationDeprecated :: Maybe Bool

    -- | A declaration of which security schemes are applied for this operation.
    -- The list of values describes alternative security schemes that can be used
    -- (that is, there is a logical OR between the security requirements).
    -- This definition overrides any declared top-level security.
    -- To remove a top-level security declaration, @Just []@ can be used.
  , _operationSecurity :: [SecurityRequirement]

    -- | An alternative server array to service this operation.
    -- If an alternative server object is specified at the 'PathItem' Object or Root level,
    -- it will be overridden by this value.
  , _operationServers :: [Server]
  } deriving (Eq, Show, Generic, Data, Typeable)

-- This instance should be in @http-media@.
instance Data MediaType where
  gunfold k z c = case constrIndex c of
    1 -> k (k (k (z (\main sub params -> foldl (/:) (main // sub) (Map.toList params)))))
    _ -> error $ "Data.Data.gunfold: Constructor " ++ show c ++ " is not of type MediaType."

  toConstr _ = mediaTypeConstr

  dataTypeOf _ = mediaTypeData

mediaTypeConstr = mkConstr mediaTypeData "MediaType" [] Prefix
mediaTypeData = mkDataType "MediaType" [mediaTypeConstr]

instance Hashable MediaType where
  hashWithSalt salt mt = salt `hashWithSalt` show mt

-- | Describes a single request body.
data RequestBody = RequestBody
  { -- | A brief description of the request body. This could contain examples of use.
    -- [CommonMark syntax](https://spec.commonmark.org/) MAY be used for rich text representation.
    _requestBodyDescription :: Maybe Text

    -- | The content of the request body.
    -- The key is a media type or media type range and the value describes it.
    -- For requests that match multiple keys, only the most specific key is applicable.
    -- e.g. @text/plain@ overrides @text/*@
  , _requestBodyContent :: InsOrdHashMap MediaType MediaTypeObject

  , _requestBodyRequired :: Maybe Bool
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | Each Media Type Object provides schema and examples for the media type identified by its key.
data MediaTypeObject = MediaTypeObject
  { _mediaTypeObjectSchema :: Maybe (Referenced Schema)

    -- | Example of the media type.
    -- The example object SHOULD be in the correct format as specified by the media type.
  , _mediaTypeObjectExample :: Maybe Value

    -- | Examples of the media type.
    -- Each example object SHOULD match the media type and specified schema if present.
  , _mediaTypeObjectExamples :: InsOrdHashMap Text (Referenced Example)

    -- | A map between a property name and its encoding information.
    -- The key, being the property name, MUST exist in the schema as a property.
    -- The encoding object SHALL only apply to 'RequestBody' objects when the media type
    -- is @multipart@ or @application/x-www-form-urlencoded@.
  , _mediaTypeObjectEncoding :: InsOrdHashMap Text Encoding
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | In order to support common ways of serializing simple parameters, a set of style values are defined.
data Style
  = StyleMatrix
    -- ^ Path-style parameters defined by [RFC6570](https://tools.ietf.org/html/rfc6570#section-3.2.7).
  | StyleLabel
    -- ^ Label style parameters defined by [RFC6570](https://tools.ietf.org/html/rfc6570#section-3.2.7).
  | StyleForm
    -- ^ Form style parameters defined by [RFC6570](https://tools.ietf.org/html/rfc6570#section-3.2.7).
    -- This option replaces @collectionFormat@ with a @csv@ (when @explode@ is false) or @multi@
    -- (when explode is true) value from OpenAPI 2.0.
  | StyleSimple
    -- ^ Simple style parameters defined by [RFC6570](https://tools.ietf.org/html/rfc6570#section-3.2.7).
    -- This option replaces @collectionFormat@ with a @csv@ value from OpenAPI 2.0.
  | StyleSpaceDelimited
    -- ^ Space separated array values.
    -- This option replaces @collectionFormat@ equal to @ssv@ from OpenAPI 2.0.
  | StylePipeDelimited
    -- ^ Pipe separated array values.
    -- This option replaces @collectionFormat@ equal to @pipes@ from OpenAPI 2.0.
  | StyleDeepObject
    -- ^ Provides a simple way of rendering nested objects using form parameters.
  deriving (Eq, Show, Generic, Data, Typeable)

-- TODO monoid

data Encoding = Encoding
  { -- | The Content-Type for encoding a specific property.
    -- Default value depends on the property type: for @string@
    -- with format being @binary@ – @application/octet-stream@;
    -- for other primitive types – @text/plain@; for object - @application/json@;
    -- for array – the default is defined based on the inner type.
    -- The value can be a specific media type (e.g. @application/json@),
    -- a wildcard media type (e.g. @image/*@), or a comma-separated list of the two types.
    _encodingContentType :: Maybe MediaType

    -- | A map allowing additional information to be provided as headers,
    -- for example @Content-Disposition@. @Content-Type@ is described separately
    -- and SHALL be ignored in this section.
    -- This property SHALL be ignored if the request body media type is not a @multipart@.
  , _encodingHeaders :: InsOrdHashMap Text (Referenced Header)

    -- | Describes how a specific property value will be serialized depending on its type.
    -- See 'Param' Object for details on the style property.
    -- The behavior follows the same values as query parameters, including default values.
    -- This property SHALL be ignored if the request body media type
    -- is not @application/x-www-form-urlencoded@.
  , _encodingStyle :: Maybe Style

    -- | When this is true, property values of type @array@ or @object@ generate
    -- separate parameters for each value of the array,
    -- or key-value-pair of the map.
    -- For other types of properties this property has no effect.
    -- When style is form, the default value is @true@. For all other styles,
    -- the default value is @false@. This property SHALL be ignored
    -- if the request body media type is not @application/x-www-form-urlencoded@.
  , _encodingExplode :: Maybe Bool

    -- | Determines whether the parameter value SHOULD allow reserved characters,
    -- as defined by [RFC3986](https://tools.ietf.org/html/rfc3986#section-2.2)
    -- @:/?#[]@!$&'()*+,;=@ to be included without percent-encoding.
    -- The default value is @false@. This property SHALL be ignored if the request body media type
    -- is not @application/x-www-form-urlencoded@.
  , _encodingAllowReserved :: Maybe Bool
  } deriving (Eq, Show, Generic, Data, Typeable)

newtype MimeList = MimeList { getMimeList :: [MediaType] }
  deriving (Eq, Show, Semigroup, Monoid, Typeable)

mimeListConstr :: Constr
mimeListConstr = mkConstr mimeListDataType "MimeList" ["getMimeList"] Prefix

mimeListDataType :: DataType
mimeListDataType = mkDataType "Data.Swagger.MimeList" [mimeListConstr]

instance Data MimeList where
  gunfold k z c = case constrIndex c of
    1 -> k (z (\xs -> MimeList (map fromString xs)))
    _ -> error $ "Data.Data.gunfold: Constructor " ++ show c ++ " is not of type MimeList."
  toConstr (MimeList _) = mimeListConstr
  dataTypeOf _ = mimeListDataType

-- | Describes a single operation parameter.
-- A unique parameter is defined by a combination of a name and location.
data Param = Param
  { -- | The name of the parameter.
    -- Parameter names are case sensitive.
    _paramName :: Text

    -- | A brief description of the parameter.
    -- This could contain examples of use.
    -- GFM syntax can be used for rich text representation.
  , _paramDescription :: Maybe Text

    -- | Determines whether this parameter is mandatory.
    -- If the parameter is in "path", this property is required and its value MUST be true.
    -- Otherwise, the property MAY be included and its default value is @False@.
  , _paramRequired :: Maybe Bool

    -- | Specifies that a parameter is deprecated and SHOULD be transitioned out of usage.
    -- Default value is @false@.
  , _paramDeprecated :: Maybe Bool

    -- | The location of the parameter.
  , _paramIn :: ParamLocation

    -- | Sets the ability to pass empty-valued parameters.
    -- This is valid only for 'ParamQuery' parameters and allows sending
    -- a parameter with an empty value. Default value is @false@.
  , _paramAllowEmptyValue :: Maybe Bool

    -- | Parameter schema.
  , _paramSchema :: Maybe (Referenced Schema)

    -- | Describes how the parameter value will be serialized depending
    -- on the type of the parameter value. Default values (based on value of '_paramIn'):
    -- for 'ParamQuery' - 'StyleForm'; for 'ParamPath' - 'StyleSimple'; for 'ParamHeader' - 'StyleSimple';
    -- for 'ParamCookie' - 'StyleForm'.
  , _paramStyle :: Maybe Style

    -- | When this is true, parameter values of type @array@ or @object@
    -- generate separate parameters for each value of the array or key-value pair of the map.
    -- For other types of parameters this property has no effect.
    -- When style is @form@, the default value is true. For all other styles, the default value is false.
  , _paramExplode :: Maybe Bool

    -- | Example of the parameter's potential value.
    -- The example SHOULD match the specified schema and encoding properties if present.
    -- The '_paramExample' field is mutually exclusive of the '_paramExamples' field.
    -- Furthermore, if referencing a schema that contains an example, the example value
    -- SHALL override the example provided by the schema. To represent examples of media types
    -- that cannot naturally be represented in JSON or YAML, a string value can contain
    -- the example with escaping where necessary.
  , _paramExample :: Maybe Value

    -- | Examples of the parameter's potential value.
    -- Each example SHOULD contain a value in the correct format as specified
    -- in the parameter encoding. The '_paramExamples' field is mutually exclusive of the '_paramExample' field.
    -- Furthermore, if referencing a schema that contains an example,
    -- the examples value SHALL override the example provided by the schema.
  , _paramExamples :: InsOrdHashMap Text (Referenced Example)
  } deriving (Eq, Show, Generic, Data, Typeable)

data Example = Example
  { -- | Short description for the example.
    _exampleSummary :: Maybe Text

    -- | Long description for the example.
    -- CommonMark syntax MAY be used for rich text representation.
  , _exampleDescription :: Maybe Text

    -- | Embedded literal example.
    -- The '_exampleValue' field and '_exampleExternalValue' field are mutually exclusive.
    --
    -- To represent examples of media types that cannot naturally represented in JSON or YAML,
    -- use a string value to contain the example, escaping where necessary.
  , _exampleValue :: Maybe Value

    -- | A URL that points to the literal example.
    -- This provides the capability to reference examples that cannot easily be included
    -- in JSON or YAML documents. The '_exampleValue' field
    -- and '_exampleExternalValue' field are mutually exclusive.
  , _exampleExternalValue :: Maybe URL
  } deriving (Eq, Show, Generic, Typeable, Data)

-- | Items for @'SwaggerArray'@ schemas.
--
-- __Warning__: OpenAPI 3.0 does not support tuple arrays. However, OpenAPI 3.1 will, as
-- it will incorporate Json Schema mostly verbatim.
--
-- @'SwaggerItemsObject'@ should be used to specify homogenous array @'Schema'@s.
--
-- @'SwaggerItemsArray'@ should be used to specify tuple @'Schema'@s.
data SwaggerItems where
  SwaggerItemsObject    :: Referenced Schema   -> SwaggerItems
  SwaggerItemsArray     :: [Referenced Schema] -> SwaggerItems
  deriving (Eq, Show, Typeable, Data)

-- | Type used as a kind to avoid overlapping instances.
data SwaggerKind t
    = SwaggerKindNormal t
    | SwaggerKindParamOtherSchema
    | SwaggerKindSchema
    deriving (Typeable)

deriving instance Typeable 'SwaggerKindNormal
deriving instance Typeable 'SwaggerKindParamOtherSchema
deriving instance Typeable 'SwaggerKindSchema

-- TODO remove
type family SwaggerKindType (k :: SwaggerKind *) :: *
type instance SwaggerKindType ('SwaggerKindNormal t) = t
type instance SwaggerKindType 'SwaggerKindSchema = Schema
--type instance SwaggerKindType 'SwaggerKindParamOtherSchema = ParamOtherSchema

data SwaggerType where
  SwaggerString   :: SwaggerType
  SwaggerNumber   :: SwaggerType
  SwaggerInteger  :: SwaggerType
  SwaggerBoolean  :: SwaggerType
  SwaggerArray    :: SwaggerType
  SwaggerNull     :: SwaggerType
  SwaggerObject   :: SwaggerType
  deriving (Eq, Show, Typeable, Generic, Data)

data ParamLocation
  = -- | Parameters that are appended to the URL.
    -- For example, in @/items?id=###@, the query parameter is @id@.
    ParamQuery
    -- | Custom headers that are expected as part of the request.
  | ParamHeader
    -- | Used together with Path Templating, where the parameter value is actually part of the operation's URL.
    -- This does not include the host or base path of the API.
    -- For example, in @/items/{itemId}@, the path parameter is @itemId@.
  | ParamPath
    -- | Used to pass a specific cookie value to the API.
  | ParamCookie
  deriving (Eq, Show, Generic, Data, Typeable)

type Format = Text

type ParamName = Text

data Schema = Schema
  { _schemaTitle :: Maybe Text
  , _schemaDescription :: Maybe Text
  , _schemaRequired :: [ParamName]

  , _schemaNullable :: Maybe Bool
  , _schemaAllOf :: Maybe [Referenced Schema]
  , _schemaOneOf :: Maybe [Referenced Schema]
  , _schemaNot :: Maybe (Referenced Schema)
  , _schemaAnyOf :: Maybe [Referenced Schema]
  , _schemaProperties :: InsOrdHashMap Text (Referenced Schema)
  , _schemaAdditionalProperties :: Maybe AdditionalProperties

  , _schemaDiscriminator :: Maybe Discriminator
  , _schemaReadOnly :: Maybe Bool
  , _schemaWriteOnly :: Maybe Bool
  , _schemaXml :: Maybe Xml
  , _schemaExternalDocs :: Maybe ExternalDocs
  , _schemaExample :: Maybe Value
  , _schemaDeprecated :: Maybe Bool

  , _schemaMaxProperties :: Maybe Integer
  , _schemaMinProperties :: Maybe Integer

  , _schemaParamSchema :: ParamSchema
  } deriving (Eq, Show, Generic, Data, Typeable)

data Discriminator = Discriminator
  { -- | The name of the property in the payload that will hold the discriminator value.
    _discriminatorPropertyName :: Text

    -- | An object to hold mappings between payload values and schema names or references.
  , _discriminatorMapping :: InsOrdHashMap Text Text
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | A @'Schema'@ with an optional name.
-- This name can be used in references.
data NamedSchema = NamedSchema
  { _namedSchemaName :: Maybe Text
  , _namedSchemaSchema :: Schema
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | Regex pattern for @string@ type.
type Pattern = Text

data ParamSchema = ParamSchema
  { -- | Declares the value of the parameter that the server will use if none is provided,
    -- for example a @"count"@ to control the number of results per page might default to @100@
    -- if not supplied by the client in the request.
    -- (Note: "default" has no meaning for required parameters.)
    -- Unlike JSON Schema this value MUST conform to the defined type for this parameter.
    _paramSchemaDefault :: Maybe Value

  , _paramSchemaType :: Maybe SwaggerType
  , _paramSchemaFormat :: Maybe Format
  , _paramSchemaItems :: Maybe SwaggerItems
  , _paramSchemaMaximum :: Maybe Scientific
  , _paramSchemaExclusiveMaximum :: Maybe Bool
  , _paramSchemaMinimum :: Maybe Scientific
  , _paramSchemaExclusiveMinimum :: Maybe Bool
  , _paramSchemaMaxLength :: Maybe Integer
  , _paramSchemaMinLength :: Maybe Integer
  , _paramSchemaPattern :: Maybe Pattern
  , _paramSchemaMaxItems :: Maybe Integer
  , _paramSchemaMinItems :: Maybe Integer
  , _paramSchemaUniqueItems :: Maybe Bool
  , _paramSchemaEnum :: Maybe [Value]
  , _paramSchemaMultipleOf :: Maybe Scientific
  } deriving (Eq, Show, Generic, Typeable, Data)

data Xml = Xml
  { -- | Replaces the name of the element/attribute used for the described schema property.
    -- When defined within the @'SwaggerItems'@ (items), it will affect the name of the individual XML elements within the list.
    -- When defined alongside type being array (outside the items),
    -- it will affect the wrapping element and only if wrapped is true.
    -- If wrapped is false, it will be ignored.
    _xmlName :: Maybe Text

    -- | The URL of the namespace definition.
    -- Value SHOULD be in the form of a URL.
  , _xmlNamespace :: Maybe Text

    -- | The prefix to be used for the name.
  , _xmlPrefix :: Maybe Text

    -- | Declares whether the property definition translates to an attribute instead of an element.
    -- Default value is @False@.
  , _xmlAttribute :: Maybe Bool

    -- | MAY be used only for an array definition.
    -- Signifies whether the array is wrapped
    -- (for example, @\<books\>\<book/\>\<book/\>\</books\>@)
    -- or unwrapped (@\<book/\>\<book/\>@).
    -- Default value is @False@.
    -- The definition takes effect only when defined alongside type being array (outside the items).
  , _xmlWrapped :: Maybe Bool
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | A container for the expected responses of an operation.
-- The container maps a HTTP response code to the expected response.
-- It is not expected from the documentation to necessarily cover all possible HTTP response codes,
-- since they may not be known in advance.
-- However, it is expected from the documentation to cover a successful operation response and any known errors.
data Responses = Responses
  { -- | The documentation of responses other than the ones declared for specific HTTP response codes.
    -- It can be used to cover undeclared responses.
   _responsesDefault :: Maybe (Referenced Response)

    -- | Any HTTP status code can be used as the property name (one property per HTTP status code).
    -- Describes the expected response for those HTTP status codes.
  , _responsesResponses :: InsOrdHashMap HttpStatusCode (Referenced Response)
  } deriving (Eq, Show, Generic, Data, Typeable)

type HttpStatusCode = Int

-- | Describes a single response from an API Operation.
data Response = Response
  { -- | A short description of the response.
    -- [CommonMark syntax](https://spec.commonmark.org/) can be used for rich text representation.
    _responseDescription :: Text

    -- | A map containing descriptions of potential response payloads.
    -- The key is a media type or media type range and the value describes it.
    -- For responses that match multiple keys, only the most specific key is applicable.
    -- e.g. @text/plain@ overrides @text/*@.
  , _responseContent :: InsOrdHashMap MediaType MediaTypeObject

    -- | Maps a header name to its definition.
  , _responseHeaders :: InsOrdHashMap HeaderName (Referenced Header)

  -- TODO links
  } deriving (Eq, Show, Generic, Data, Typeable)

instance IsString Response where
  fromString s = Response (fromString s) mempty mempty

type HeaderName = Text


-- TODO this is mostly a copy of 'Param'.
data Header = Header
  { -- | A short description of the header.
    _headerDescription :: Maybe Text

  , _headerSchema :: Maybe (Referenced Schema)
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | The location of the API key.
data ApiKeyLocation
  = ApiKeyQuery
  | ApiKeyHeader
  | ApiKeyCookie
  deriving (Eq, Show, Generic, Data, Typeable)

data ApiKeyParams = ApiKeyParams
  { -- | The name of the header or query parameter to be used.
    _apiKeyName :: Text

    -- | The location of the API key.
  , _apiKeyIn :: ApiKeyLocation
  } deriving (Eq, Show, Generic, Data, Typeable)

-- | The authorization URL to be used for OAuth2 flow. This SHOULD be in the form of a URL.
type AuthorizationURL = Text

-- | The token URL to be used for OAuth2 flow. This SHOULD be in the form of a URL.
type TokenURL = Text

data OAuth2ImplicitFlow = OAuth2ImplicitFlow
  { _oAuth2ImplicitFlowAuthorizationUrl :: AuthorizationURL
  } deriving (Eq, Show, Generic, Data, Typeable)

data OAuth2PasswordFlow = OAuth2PasswordFlow
  { _oAuth2PasswordFlowTokenUrl :: TokenURL
  } deriving (Eq, Show, Generic, Data, Typeable)

data OAuth2ClientCredentialsFlow = OAuth2ClientCredentialsFlow
  { _oAuth2ClientCredentialsFlowTokenUrl :: TokenURL
  } deriving (Eq, Show, Generic, Data, Typeable)

data OAuth2AuthorizationCodeFlow = OAuth2AuthorizationCodeFlow
  { _oAuth2AuthorizationCodeFlowAuthorizationUrl :: AuthorizationURL
  , _oAuth2AuthorizationCodeFlowTokenUrl :: TokenURL
  } deriving (Eq, Show, Generic, Data, Typeable)

data OAuth2Flow p = OAuth2Flow
  { _oAuth2Params :: p

    -- | The URL to be used for obtaining refresh tokens.
  , _oAath2RefreshUrl :: Maybe URL

    -- | The available scopes for the OAuth2 security scheme.
    -- A map between the scope name and a short description for it.
    -- The map MAY be empty.
  , _oAuth2Scopes :: InsOrdHashMap Text Text
  } deriving (Eq, Show, Generic, Data, Typeable)

data OAuth2Flows = OAuth2Flows
  { -- | Configuration for the OAuth Implicit flow
    _oAuth2FlowsImplicit :: Maybe (OAuth2Flow OAuth2ImplicitFlow)

    -- | Configuration for the OAuth Resource Owner Password flow
  , _oAuth2FlowsPassword :: Maybe (OAuth2Flow OAuth2PasswordFlow)

    -- | Configuration for the OAuth Client Credentials flow
  , _oAuth2FlowsClientCredentials :: Maybe (OAuth2Flow OAuth2ClientCredentialsFlow)

    -- | Configuration for the OAuth Authorization Code flow
  , _oAuth2FlowsAuthorizationCode :: Maybe (OAuth2Flow OAuth2AuthorizationCodeFlow)
  } deriving (Eq, Show, Generic, Data, Typeable)

data SecuritySchemeType
  = SecuritySchemeHttp
  | SecuritySchemeApiKey ApiKeyParams
  | SecuritySchemeOAuth2 OAuth2Flows
  | SecuritySchemeOpenIdConnect URL
  deriving (Eq, Show, Generic, Data, Typeable)

data SecurityScheme = SecurityScheme
  { -- | The type of the security scheme.
    _securitySchemeType :: SecuritySchemeType

    -- | A short description for security scheme.
  , _securitySchemeDescription :: Maybe Text
  } deriving (Eq, Show, Generic, Data, Typeable)

newtype SecurityDefinitions
  = SecurityDefinitions (Definitions SecurityScheme)
  deriving (Eq, Show, Generic, Data, Typeable)

-- | Lists the required security schemes to execute this operation.
-- The object can have multiple security schemes declared in it which are all required
-- (that is, there is a logical AND between the schemes).
newtype SecurityRequirement = SecurityRequirement
  { getSecurityRequirement :: InsOrdHashMap Text [Text]
  } deriving (Eq, Read, Show, Semigroup, Monoid, ToJSON, FromJSON, Data, Typeable)

-- | Tag name.
type TagName = Text

-- | Allows adding meta data to a single tag that is used by @Operation@.
-- It is not mandatory to have a @Tag@ per tag used there.
data Tag = Tag
  { -- | The name of the tag.
    _tagName :: TagName

    -- | A short description for the tag.
    -- GFM syntax can be used for rich text representation.
  , _tagDescription :: Maybe Text

    -- | Additional external documentation for this tag.
  , _tagExternalDocs :: Maybe ExternalDocs
  } deriving (Eq, Ord, Show, Generic, Data, Typeable)

instance Hashable Tag

instance IsString Tag where
  fromString s = Tag (fromString s) Nothing Nothing

-- | Allows referencing an external resource for extended documentation.
data ExternalDocs = ExternalDocs
  { -- | A short description of the target documentation.
    -- GFM syntax can be used for rich text representation.
    _externalDocsDescription :: Maybe Text

    -- | The URL for the target documentation.
  , _externalDocsUrl :: URL
  } deriving (Eq, Ord, Show, Generic, Data, Typeable)

instance Hashable ExternalDocs

-- | A simple object to allow referencing other definitions in the specification.
-- It can be used to reference parameters and responses that are defined at the top level for reuse.
newtype Reference = Reference { getReference :: Text }
  deriving (Eq, Show, Data, Typeable)

data Referenced a
  = Ref Reference
  | Inline a
  deriving (Eq, Show, Functor, Data, Typeable)

instance IsString a => IsString (Referenced a) where
  fromString = Inline . fromString

newtype URL = URL { getUrl :: Text } deriving (Eq, Ord, Show, Hashable, ToJSON, FromJSON, Data, Typeable)

data AdditionalProperties
  = AdditionalPropertiesAllowed Bool
  | AdditionalPropertiesSchema (Referenced Schema)
  deriving (Eq, Show, Data, Typeable)

-------------------------------------------------------------------------------
-- Generic instances
-------------------------------------------------------------------------------

deriveGeneric ''Server
deriveGeneric ''Components
deriveGeneric ''Header
deriveGeneric ''OAuth2Flow
deriveGeneric ''OAuth2Flows
deriveGeneric ''Operation
deriveGeneric ''Param
deriveGeneric ''PathItem
deriveGeneric ''Response
deriveGeneric ''RequestBody
deriveGeneric ''MediaTypeObject
deriveGeneric ''Responses
deriveGeneric ''SecurityScheme
deriveGeneric ''Schema
deriveGeneric ''ParamSchema
deriveGeneric ''Swagger
deriveGeneric ''Example
deriveGeneric ''Encoding

-- =======================================================================
-- Monoid instances
-- =======================================================================

instance Semigroup Swagger where
  (<>) = genericMappend
instance Monoid Swagger where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Info where
  (<>) = genericMappend
instance Monoid Info where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Contact where
  (<>) = genericMappend
instance Monoid Contact where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Components where
  (<>) = genericMappend
instance Monoid Components where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup PathItem where
  (<>) = genericMappend
instance Monoid PathItem where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Schema where
  (<>) = genericMappend
instance Monoid Schema where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup ParamSchema where
  (<>) = genericMappend
instance Monoid ParamSchema where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Param where
  (<>) = genericMappend
instance Monoid Param where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Header where
  (<>) = genericMappend
instance Monoid Header where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Responses where
  (<>) = genericMappend
instance Monoid Responses where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Response where
  (<>) = genericMappend
instance Monoid Response where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup MediaTypeObject where
  (<>) = genericMappend
instance Monoid MediaTypeObject where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup ExternalDocs where
  (<>) = genericMappend
instance Monoid ExternalDocs where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup Operation where
  (<>) = genericMappend
instance Monoid Operation where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup (OAuth2Flow p) where
  l@OAuth2Flow{ _oAath2RefreshUrl = lUrl, _oAuth2Scopes = lScopes }
    <> OAuth2Flow { _oAath2RefreshUrl = rUrl, _oAuth2Scopes = rScopes } =
      l { _oAath2RefreshUrl = swaggerMappend lUrl rUrl, _oAuth2Scopes = lScopes <> rScopes }

-- swaggerMappend has First-like semantics, and here we need mappend'ing under Maybes.
instance Semigroup OAuth2Flows where
  l <> r = OAuth2Flows
    { _oAuth2FlowsImplicit = _oAuth2FlowsImplicit l <> _oAuth2FlowsImplicit r
    , _oAuth2FlowsPassword = _oAuth2FlowsPassword l <> _oAuth2FlowsPassword r
    , _oAuth2FlowsClientCredentials = _oAuth2FlowsClientCredentials l <> _oAuth2FlowsClientCredentials r
    , _oAuth2FlowsAuthorizationCode = _oAuth2FlowsAuthorizationCode l <> _oAuth2FlowsAuthorizationCode r
    }

instance Monoid OAuth2Flows where
  mempty = genericMempty
  mappend = (<>)

instance Semigroup SecurityScheme where
  SecurityScheme (SecuritySchemeOAuth2 lFlows) lDesc
    <> SecurityScheme (SecuritySchemeOAuth2 rFlows) rDesc =
      SecurityScheme (SecuritySchemeOAuth2 $ lFlows <> rFlows) (swaggerMappend lDesc rDesc)
  l <> _ = l

instance Semigroup SecurityDefinitions where
  (SecurityDefinitions sd1) <> (SecurityDefinitions sd2) =
     SecurityDefinitions $ InsOrdHashMap.unionWith (<>) sd1 sd2

instance Monoid SecurityDefinitions where
  mempty = SecurityDefinitions InsOrdHashMap.empty
  mappend = (<>)

instance Semigroup RequestBody where
  (<>) = genericMappend
instance Monoid RequestBody where
  mempty = genericMempty
  mappend = (<>)

-- =======================================================================
-- SwaggerMonoid helper instances
-- =======================================================================

instance SwaggerMonoid Info
instance SwaggerMonoid Components
instance SwaggerMonoid PathItem
instance SwaggerMonoid Schema
instance SwaggerMonoid ParamSchema
instance SwaggerMonoid Param
instance SwaggerMonoid Responses
instance SwaggerMonoid Response
instance SwaggerMonoid ExternalDocs
instance SwaggerMonoid Operation
instance (Eq a, Hashable a) => SwaggerMonoid (InsOrdHashSet a)

instance SwaggerMonoid MimeList
deriving instance SwaggerMonoid URL

instance SwaggerMonoid SwaggerType where
  swaggerMempty = SwaggerString
  swaggerMappend _ y = y

instance SwaggerMonoid ParamLocation where
  swaggerMempty = ParamQuery
  swaggerMappend _ y = y

instance {-# OVERLAPPING #-} SwaggerMonoid (InsOrdHashMap FilePath PathItem) where
  swaggerMempty = InsOrdHashMap.empty
  swaggerMappend = InsOrdHashMap.unionWith mappend

instance Monoid a => SwaggerMonoid (Referenced a) where
  swaggerMempty = Inline mempty
  swaggerMappend (Inline x) (Inline y) = Inline (mappend x y)
  swaggerMappend _ y = y

-- =======================================================================
-- Simple Generic-based ToJSON instances
-- =======================================================================

instance ToJSON Style where
  toJSON = genericToJSON (jsonPrefix "Style")

instance ToJSON SwaggerType where
  toJSON = genericToJSON (jsonPrefix "Swagger")

instance ToJSON ParamLocation where
  toJSON = genericToJSON (jsonPrefix "Param")

instance ToJSON Info where
  toJSON = genericToJSON (jsonPrefix "Info")

instance ToJSON Contact where
  toJSON = genericToJSON (jsonPrefix "Contact")

instance ToJSON License where
  toJSON = genericToJSON (jsonPrefix "License")

instance ToJSON ServerVariable where
  toJSON = genericToJSON (jsonPrefix "ServerVariable")

instance ToJSON ApiKeyLocation where
  toJSON = genericToJSON (jsonPrefix "ApiKey")

instance ToJSON ApiKeyParams where
  toJSON = genericToJSON (jsonPrefix "apiKey")

instance ToJSON Tag where
  toJSON = genericToJSON (jsonPrefix "Tag")

instance ToJSON ExternalDocs where
  toJSON = genericToJSON (jsonPrefix "ExternalDocs")

instance ToJSON Xml where
  toJSON = genericToJSON (jsonPrefix "Xml")

instance ToJSON Discriminator where
  toJSON = genericToJSON (jsonPrefix "Discriminator")

instance ToJSON OAuth2ImplicitFlow where
  toJSON = genericToJSON (jsonPrefix "OAuth2ImplicitFlow")

instance ToJSON OAuth2PasswordFlow where
  toJSON = genericToJSON (jsonPrefix "OAuth2PasswordFlow")

instance ToJSON OAuth2ClientCredentialsFlow where
  toJSON = genericToJSON (jsonPrefix "OAuth2ClientCredentialsFlow")

instance ToJSON OAuth2AuthorizationCodeFlow where
  toJSON = genericToJSON (jsonPrefix "OAuth2AuthorizationCodeFlow")

-- =======================================================================
-- Simple Generic-based FromJSON instances
-- =======================================================================

instance FromJSON Style where
  parseJSON = genericParseJSON (jsonPrefix "Style")

instance FromJSON SwaggerType where
  parseJSON = genericParseJSON (jsonPrefix "Swagger")

instance FromJSON ParamLocation where
  parseJSON = genericParseJSON (jsonPrefix "Param")

instance FromJSON Info where
  parseJSON = genericParseJSON (jsonPrefix "Info")

instance FromJSON Contact where
  parseJSON = genericParseJSON (jsonPrefix "Contact")

instance FromJSON License where
  parseJSON = genericParseJSON (jsonPrefix "License")

instance FromJSON ServerVariable where
  parseJSON = genericParseJSON (jsonPrefix "ServerVariable")

instance FromJSON ApiKeyLocation where
  parseJSON = genericParseJSON (jsonPrefix "ApiKey")

instance FromJSON ApiKeyParams where
  parseJSON = genericParseJSON (jsonPrefix "apiKey")

instance FromJSON Tag where
  parseJSON = genericParseJSON (jsonPrefix "Tag")

instance FromJSON ExternalDocs where
  parseJSON = genericParseJSON (jsonPrefix "ExternalDocs")

instance FromJSON Discriminator where
  parseJSON = genericParseJSON (jsonPrefix "Discriminator")

instance FromJSON OAuth2ImplicitFlow where
  parseJSON = genericParseJSON (jsonPrefix "OAuth2ImplicitFlow")

instance FromJSON OAuth2PasswordFlow where
  parseJSON = genericParseJSON (jsonPrefix "OAuth2PasswordFlow")

instance FromJSON OAuth2ClientCredentialsFlow where
  parseJSON = genericParseJSON (jsonPrefix "OAuth2ClientCredentialsFlow")

instance FromJSON OAuth2AuthorizationCodeFlow where
  parseJSON = genericParseJSON (jsonPrefix "OAuth2AuthorizationCodeFlow")

-- =======================================================================
-- Manual ToJSON instances
-- =======================================================================

instance ToJSON MediaType where
  toJSON = toJSON . show
  toEncoding = toEncoding . show

instance ToJSONKey MediaType where
  toJSONKey = JSON.toJSONKeyText (Text.pack . show)

instance (Eq p, ToJSON p, AesonDefaultValue p) => ToJSON (OAuth2Flow p) where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON OAuth2Flows where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON SecuritySchemeType where
  toJSON SecuritySchemeHttp
      = object [ "type" .= ("http" :: Text) ]
  toJSON (SecuritySchemeApiKey params)
      = toJSON params
    <+> object [ "type" .= ("apiKey" :: Text) ]
  toJSON (SecuritySchemeOAuth2 params) = object
    [ "type" .= ("oauth2" :: Text)
    , "flows" .= toJSON params
    ]
  toJSON (SecuritySchemeOpenIdConnect url) = object
    [ "type" .= ("openIdConnect" :: Text)
    , "openIdConnectUrl" .= url
    ]

instance ToJSON Swagger where
  toJSON a = sopSwaggerGenericToJSON a &
    if InsOrdHashMap.null (_swaggerPaths a)
    then (<+> object ["paths" .= object []])
    else id
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Server where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON SecurityScheme where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Schema where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Header where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

-- | As for nullary schema for 0-arity type constructors, see
-- <https://github.com/GetShopTV/swagger2/issues/167>.
--
-- >>> encode (SwaggerItemsArray [])
-- "{\"example\":[],\"items\":{},\"maxItems\":0}"
--
instance ToJSON SwaggerItems where
  toJSON (SwaggerItemsObject x) = object [ "items" .= x ]
  toJSON (SwaggerItemsArray  []) = object
    [ "items" .= object []
    , "maxItems" .= (0 :: Int)
    , "example" .= Array mempty
    ]
  toJSON (SwaggerItemsArray  x) = object [ "items" .= x ]

instance ToJSON Components where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON MimeList where
  toJSON (MimeList xs) = toJSON (map show xs)

instance ToJSON Param where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Responses where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Response where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Operation where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON PathItem where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON RequestBody where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON MediaTypeObject where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Example where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON Encoding where
  toJSON = sopSwaggerGenericToJSON
  toEncoding = sopSwaggerGenericToEncoding

instance ToJSON SecurityDefinitions where
  toJSON (SecurityDefinitions sd) = toJSON sd

instance ToJSON Reference where
  toJSON (Reference ref) = object [ "$ref" .= ref ]

referencedToJSON :: ToJSON a => Text -> Referenced a -> Value
referencedToJSON prefix (Ref (Reference ref)) = object [ "$ref" .= (prefix <> ref) ]
referencedToJSON _ (Inline x) = toJSON x

instance ToJSON (Referenced Schema)   where toJSON = referencedToJSON "#/components/schemas/"
instance ToJSON (Referenced Param)    where toJSON = referencedToJSON "#/components/parameters/"
instance ToJSON (Referenced Response) where toJSON = referencedToJSON "#/components/responses/"
instance ToJSON (Referenced RequestBody) where toJSON = referencedToJSON "#/components/requestBodies/"
instance ToJSON (Referenced Example)  where toJSON = referencedToJSON "#/components/examples/"
instance ToJSON (Referenced Header)   where toJSON = referencedToJSON "#/components/headers/"

instance ToJSON ParamSchema where
  -- TODO: this is a bit fishy, why we need sub object only in `ToJSON`?
  toJSON = sopSwaggerGenericToJSONWithOpts $
      mkSwaggerAesonOptions "paramSchema" & saoSubObject ?~ "items"

instance ToJSON AdditionalProperties where
  toJSON (AdditionalPropertiesAllowed b) = toJSON b
  toJSON (AdditionalPropertiesSchema s) = toJSON s

-- =======================================================================
-- Manual FromJSON instances
-- =======================================================================

instance FromJSON MediaType where
  parseJSON = withText "MediaType" $ \str ->
    maybe (fail $ "Invalid media type literal " <> Text.unpack str) pure $ parseAccept $ encodeUtf8 str

instance FromJSONKey MediaType where
  fromJSONKey = FromJSONKeyTextParser (parseJSON . String)

instance (Eq p, FromJSON p, AesonDefaultValue p) => FromJSON (OAuth2Flow p) where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON OAuth2Flows where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON SecuritySchemeType where
  parseJSON js@(Object o) = do
    (t :: Text) <- o .: "type"
    case t of
      "http"   -> pure SecuritySchemeHttp
      "apiKey" -> SecuritySchemeApiKey <$> parseJSON js
      "oauth2" -> SecuritySchemeOAuth2 <$> (o .: "flows")
      "openIdConnect" -> SecuritySchemeOpenIdConnect <$> (o .: "openIdConnectUrl")
      _ -> empty
  parseJSON _ = empty

instance FromJSON Swagger where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Server where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON SecurityScheme where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Schema where
  parseJSON = fmap nullaryCleanup . sopSwaggerGenericParseJSON
    where nullaryCleanup :: Schema -> Schema
          nullaryCleanup s@Schema{_schemaParamSchema=ps} =
            if _paramSchemaItems ps == Just (SwaggerItemsArray [])
              then s { _schemaExample = Nothing
                     , _schemaParamSchema = ps { _paramSchemaMaxItems = Nothing } }
              else s

instance FromJSON Header where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON SwaggerItems where
  parseJSON js@(Object obj)
      | null obj  = pure $ SwaggerItemsArray [] -- Nullary schema.
      | otherwise = SwaggerItemsObject <$> parseJSON js
  parseJSON js@(Array _)  = SwaggerItemsArray  <$> parseJSON js
  parseJSON _ = empty

instance FromJSON Components where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON MimeList where
  parseJSON js = (MimeList . map fromString) <$> parseJSON js

instance FromJSON Param where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Responses where
  parseJSON (Object o) = Responses
    <$> o .:? "default"
    <*> (parseJSON (Object (HashMap.delete "default" o)))
  parseJSON _ = empty

instance FromJSON Example where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Response where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Operation where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON PathItem where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON SecurityDefinitions where
  parseJSON js = SecurityDefinitions <$> parseJSON js

instance FromJSON RequestBody where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON MediaTypeObject where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Encoding where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON Reference where
  parseJSON (Object o) = Reference <$> o .: "$ref"
  parseJSON _ = empty

referencedParseJSON :: FromJSON a => Text -> Value -> JSON.Parser (Referenced a)
referencedParseJSON prefix js@(Object o) = do
  ms <- o .:? "$ref"
  case ms of
    Nothing -> Inline <$> parseJSON js
    Just s  -> Ref <$> parseRef s
  where
    parseRef s = do
      case Text.stripPrefix prefix s of
        Nothing     -> fail $ "expected $ref of the form \"" <> Text.unpack prefix <> "*\", but got " <> show s
        Just suffix -> pure (Reference suffix)
referencedParseJSON _ _ = fail "referenceParseJSON: not an object"

instance FromJSON (Referenced Schema)   where parseJSON = referencedParseJSON "#/components/schemas/"
instance FromJSON (Referenced Param)    where parseJSON = referencedParseJSON "#/components/parameters/"
instance FromJSON (Referenced Response) where parseJSON = referencedParseJSON "#/components/responses/"
instance FromJSON (Referenced RequestBody) where parseJSON = referencedParseJSON "#/components/requestBodies/"
instance FromJSON (Referenced Example)  where parseJSON = referencedParseJSON "#/components/examples/"
instance FromJSON (Referenced Header)   where parseJSON = referencedParseJSON "#/components/headers/"

instance FromJSON Xml where
  parseJSON = genericParseJSON (jsonPrefix "xml")

instance FromJSON ParamSchema where
  parseJSON = sopSwaggerGenericParseJSON

instance FromJSON AdditionalProperties where
  parseJSON (Bool b) = pure $ AdditionalPropertiesAllowed b
  parseJSON js = AdditionalPropertiesSchema <$> parseJSON js

instance HasSwaggerAesonOptions Server where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "server"
instance HasSwaggerAesonOptions Components where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "components"
instance HasSwaggerAesonOptions Header where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "header"
instance AesonDefaultValue p => HasSwaggerAesonOptions (OAuth2Flow p) where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "oauth2" & saoSubObject ?~ "params"
instance HasSwaggerAesonOptions OAuth2Flows where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "oauth2Flows"
instance HasSwaggerAesonOptions Operation where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "operation"
instance HasSwaggerAesonOptions Param where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "param"
instance HasSwaggerAesonOptions PathItem where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "pathItem"
instance HasSwaggerAesonOptions Response where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "response"
instance HasSwaggerAesonOptions RequestBody where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "requestBody"
instance HasSwaggerAesonOptions MediaTypeObject where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "mediaTypeObject"
instance HasSwaggerAesonOptions Responses where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "responses" & saoSubObject ?~ "responses"
instance HasSwaggerAesonOptions SecurityScheme where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "securityScheme" & saoSubObject ?~ "type"
instance HasSwaggerAesonOptions Schema where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "schema" & saoSubObject ?~ "paramSchema"
instance HasSwaggerAesonOptions Swagger where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "swagger" & saoAdditionalPairs .~ [("openapi", "3.0.0")]
instance HasSwaggerAesonOptions Example where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "example"
instance HasSwaggerAesonOptions Encoding where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "encoding"

instance HasSwaggerAesonOptions ParamSchema where
  swaggerAesonOptions _ = mkSwaggerAesonOptions "paramSchema"

instance AesonDefaultValue Server
instance AesonDefaultValue Components
instance AesonDefaultValue ParamSchema
instance AesonDefaultValue OAuth2ImplicitFlow
instance AesonDefaultValue OAuth2PasswordFlow
instance AesonDefaultValue OAuth2ClientCredentialsFlow
instance AesonDefaultValue OAuth2AuthorizationCodeFlow
instance AesonDefaultValue p => AesonDefaultValue (OAuth2Flow p)
instance AesonDefaultValue Responses
instance AesonDefaultValue SecuritySchemeType
instance AesonDefaultValue SwaggerType
instance AesonDefaultValue MimeList where defaultValue = Just mempty
instance AesonDefaultValue Info
instance AesonDefaultValue ParamLocation
